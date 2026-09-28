#!/usr/bin/env bash
# Tests for qwen-voice-bridge.py — the hub between Home Assistant (office
# voice + the app) and the OpenCode server that runs the lab's observer.
#
# WHY. The observer reads the whole lab; the microphone also hears the TV. The
# properties that matter:
#   * no token, wrong token: 404, and nothing reaches OpenCode;
#   * the VOICE never approves: a voice turn that hits an approval says so and
#     returns, and no reply is sent to OpenCode;
#   * the app approves only a request that is really pending, through
#     OpenCode's own reply endpoint, and history says who decided;
#   * voice goes to the ACTIVE session; add / rename / remove / clear keep the
#     manifest, OpenCode and tmux in step;
#   * a turn Alibaba's filter refuses is asked again to the fallback model, in
#     the SAME conversation;
#   * a turn that outlives the voice (slow, or waiting on an approval) has its
#     FINAL answer kept for the office announcement.
#
# OpenCode is replaced by a fake HTTP server speaking the same endpoints and
# event shapes as opencode 1.18.32 (captured 2026-09-27: permission.asked,
# permission.replied, session.idle); tmux by a fake that records windows.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUB="$SCRIPTS/qwen-voice-bridge.py"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/qhub-test.XXXXXX")
PIDS=()
cleanup() { kill "${PIDS[@]}" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT
pass=0; failed=0
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', wanted '$3'"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: output lacks '$3'";; esac; }

TOKEN=test-token-123
PORT=$((20000 + RANDOM % 20000)); OCPORT=$((PORT + 1))
STATE="$ROOT/state"; mkdir -p "$STATE"
echo plain > "$ROOT/mode"
printf 'secret-oc' > "$STATE/opencode-password"
OCAUTH="Basic $(printf opencode:secret-oc | base64)"

# --- fake OpenCode ----------------------------------------------------------
cat > "$ROOT/fake-oc.py" <<'EOF'
import base64, json, os, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root, port = sys.argv[1], int(sys.argv[2])
S = {}; PERM = {}; SUBS = []; LOG = open(os.path.join(root, "oc.log"), "a")
AUTH = "Basic " + base64.b64encode(b"opencode:secret-oc").decode()
def emit(t, p):
    d = ("data: " + json.dumps({"type": t, "properties": p}) + "\n\n").encode()
    for q in list(SUBS): q.append(d)
def say(sid, text, err=None):
    info = {"role": "assistant", "error": err} if err else {"role": "assistant"}
    S[sid]["msgs"].append({"info": info, "parts": [{"type": "text", "text": text}]})
def turn(sid, body):
    mode = open(os.path.join(root, "mode")).read().strip()
    text = body["parts"][0]["text"]; model = body.get("model")
    S[sid]["msgs"].append({"info": {"role": "user"}, "parts": [{"type": "text", "text": text}]})
    LOG.write(json.dumps({"sid": sid, "text": text, "model": model, "agent": body.get("agent")}) + "\n"); LOG.flush()
    if mode == "filtered" and not model:
        say(sid, "", {"name": "UnknownError", "data": {"message": "400 InternalError.Algo.DataInspectionFailed"}})
    elif mode == "slow":
        time.sleep(4.5); say(sid, f"Réponse lente ({S[sid]['title']}).")
    elif mode in ("approval", "terminal-approves"):
        pid = "per_" + uuid.uuid4().hex[:12]
        PERM[pid] = {"id": pid, "sessionID": sid, "permission": "bash", "patterns": ["rm -rf /tmp/x"],
                     "metadata": {"command": "rm -rf /tmp/x"}}
        emit("permission.asked", PERM[pid])
        if mode == "terminal-approves":
            time.sleep(0.5); PERM.pop(pid)
            emit("permission.replied", {"sessionID": sid, "requestID": pid, "reply": "reject"})
            say(sid, "refusé au terminal"); emit("session.idle", {"sessionID": sid})
        return
    elif mode == "api-error":
        say(sid, "", {"name": "APIError", "data": {"message": "Paid model training violation (account settings)"}})
    elif mode == "silent":
        return
    else:
        say(sid, ("Repli : " if model else "") + f"Cinquante-six ({S[sid]['title']}).")
    emit("session.idle", {"sessionID": sid})
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def js(self, code, obj=None):
        d = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return json.loads(self.rfile.read(n) or b"{}")
    def ok(self):
        if self.headers.get("Authorization") != AUTH: self.js(401, {"error": "auth"}); return False
        return True
    def do_GET(self):
        if not self.ok(): return
        p = self.path.split("?")[0]
        if p == "/session": return self.js(200, [{"id": k, "title": v["title"], "directory": v["dir"]} for k, v in S.items()])
        if p == "/permission": return self.js(200, list(PERM.values()))
        if p.startswith("/session/") and p.endswith("/message"):
            return self.js(200, S[p.split("/")[2]]["msgs"][-6:])
        if p == "/event":
            q = []; SUBS.append(q)
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            try:
                while True:
                    while q: self.wfile.write(q.pop(0)); self.wfile.flush()
                    time.sleep(0.05)
            except Exception: SUBS.remove(q)
            return
        self.js(404)
    def do_POST(self):
        if not self.ok(): return
        p = self.path; b = self.body()
        if p == "/session":
            sid = "ses_" + uuid.uuid4().hex[:12]; S[sid] = {"title": b.get("title", ""), "dir": root, "msgs": []}
            return self.js(200, {"id": sid})
        if p.endswith("/prompt_async"):
            sid = p.split("/")[2]; threading.Thread(target=turn, args=(sid, b), daemon=True).start()
            return self.js(204)
        if p.startswith("/permission/") and p.endswith("/reply"):
            pid = p.split("/")[2]; q = PERM.pop(pid, None)
            if not q: return self.js(404)
            LOG.write(json.dumps({"reply": pid, "value": b["reply"]}) + "\n"); LOG.flush()
            emit("permission.replied", {"sessionID": q["sessionID"], "requestID": pid, "reply": b["reply"]})
            say(q["sessionID"], "fait" if b["reply"] == "once" else "refusé"); emit("session.idle", {"sessionID": q["sessionID"]})
            return self.js(200, True)
        self.js(404)
    def do_PATCH(self):
        if not self.ok(): return
        b = self.body(); s = S[self.path.split("/")[2]]
        if "title" in b: s["title"] = b["title"]
        if "directory" in b: s["dir"] = b["directory"]   # test hook: a session from an older workdir
        self.js(200, {})
    def do_DELETE(self):
        if not self.ok(): return
        S.pop(self.path.split("/")[2], None); self.js(200, True)
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
EOF

cat > "$ROOT/fake-tmux.sh" <<'EOF'
#!/usr/bin/env bash
W="$(dirname "$0")/windows"; touch "$W"
arg() { local want=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
target() { arg -t "$@" | sed 's/^observateur:=\{0,1\}//'; }
case "$1" in
  -V) echo fake;;
  has-session) [ -s "$W" ];;
  list-windows) [ -s "$W" ] || exit 1; cut -d'|' -f1 "$W";;
  new-session|new-window) echo "$(arg -n "$@")|${@: -1}" >> "$W";;
  kill-window) n=$(target "$@"); grep -v "^$n|" "$W" > "$W.t"; mv "$W.t" "$W";;
  rename-window) o=$(target "$@"); n="${@: -1}"; sed -i "s/^$o|/$n|/" "$W";;
  respawn-window) n=$(target "$@"); c="${@: -1}"; grep -v "^$n|" "$W" > "$W.t"; echo "$n|$c" >> "$W.t"; mv "$W.t" "$W";;
esac
EOF
chmod +x "$ROOT/fake-tmux.sh"

python3 "$ROOT/fake-oc.py" "$ROOT" "$OCPORT" & PIDS+=($!)
start_hub() {
  QWEN_VOICE_STATE="$STATE" QWEN_VOICE_TOKEN="$TOKEN" QWEN_VOICE_PORT="$PORT" QWEN_VOICE_TIMEOUT=3 \
  QWEN_OPENCODE_URL="http://127.0.0.1:$OCPORT" QWEN_TMUX="bash $ROOT/fake-tmux.sh" \
  QWEN_SERVE=/x/serve.sh QWEN_ATTACH=/x/attach.sh QWEN_WORKDIR="$ROOT" QWEN_FALLBACK_MODEL=openrouter/qwen/qwen3.8-27b \
    python3 "$HUB" 2>>"$ROOT/hub.log" & HUB_PID=$!; PIDS+=($HUB_PID)
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
}
start_hub

get()  { curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT$1"; }
post() { curl -s -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" -X POST "http://127.0.0.1:$PORT$1" -d "$2"; }
st()   { get /qwen/state | python3 -c "import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
chat() { curl -s -w '\n%{http_code}' -X POST ${1:+-H "Authorization: Bearer $1"} "http://127.0.0.1:$PORT/api/chat" -d "$2"; }
answer() { python3 -c 'import sys,json; print("".join(json.loads(l).get("message",{}).get("content","") for l in sys.stdin if l.strip().startswith("{")))'; }
wait_for() { for _ in $(seq 1 60); do [ "$(st "$1")" = "$2" ] && return 0; sleep 0.1; done; return 1; }
BODY='{"model":"qwen-tmux:latest","stream":true,"messages":[{"role":"system","content":"PROMPT DE HA"},{"role":"user","content":"ancienne"},{"role":"user","content":"Combien font sept fois huit?"}]}'
replies() { grep -c '"reply"' "$ROOT/oc.log" 2>/dev/null || echo 0; }

say "first start"
wait_for "d['names']" "['bureau']" && ok "creates « bureau » as an OpenCode session" || bad "no bureau: $(get /qwen/state)"
has "starts the OpenCode server window" "$(cut -d'|' -f1 "$ROOT/windows")" gaming-01
has "…and a terminal window attached to bureau" "$(grep '^bureau|' "$ROOT/windows")" "attach.sh ses_"

say "authentication"
is "no token -> 404" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/qwen/state")" 404
r=$(chat nope "$BODY"); is "wrong token cannot chat" "$(tail -1 <<<"$r")" 404
[ -s "$ROOT/oc.log" ] && bad "a refused request reached OpenCode" || ok "nothing reached OpenCode"

say "voice: active session, last sentence only, observer agent"
r=$(chat "$TOKEN" "$BODY"); is "answer from bureau" "$(head -n -1 <<<"$r" | answer)" "Cinquante-six (bureau)."
q=$(tail -1 "$ROOT/oc.log")
has "only the last sentence" "$q" "Combien font sept fois huit?"
case $q in *"PROMPT DE HA"*|*ancienne*) bad "HA prompt or history leaked";; *) ok "no HA prompt, no history";; esac
has "sent to the observer agent" "$q" '"agent": "observateur"'

say "sessions"
r=$(post /qwen/session '{"action":"add"}'); is "add -> 200" "$(tail -1 <<<"$r")" 200
second=$(head -n -1 <<<"$r" | python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])')
post /qwen/session "{\"action\":\"activate\",\"name\":\"$second\"}" >/dev/null
r=$(chat "$TOKEN" "$BODY"); is "voice follows the active session" "$(head -n -1 <<<"$r" | answer)" "Cinquante-six ($second)."
r=$(post /qwen/session '{"action":"rename","name":"bureau","new":"Pas Bon!"}'); is "bad name refused" "$(tail -1 <<<"$r")" 409
r=$(post /qwen/session '{"action":"add","name":"gaming-01"}'); is "add ignores a forced name" "$(tail -1 <<<"$r")" 200

say "approvals: the voice never approves, the app does"
echo approval > "$ROOT/mode"; n0=$(replies)
r=$(chat "$TOKEN" "$BODY"); has "voice says to approve elsewhere" "$(head -n -1 <<<"$r" | answer)" "OK"
is "the voice sent no reply" "$(replies)" "$n0"
wait_for "len(d['pending'])" 1 && ok "one pending approval" || bad "pending not seen: $(get /qwen/state)"
rid=$(st "d['pending'][0]['id']")
is "…in the right session" "$(st "d['pending'][0]['session']")" "$second"
is "…with the exact command" "$(st "d['pending'][0]['summary']")" "rm -rf /tmp/x"
r=$(post /qwen/approve '{"request_id":"per_nope","allowed":true}'); is "unknown request refused" "$(tail -1 <<<"$r")" 409
is "…and nothing sent" "$(replies)" "$n0"
r=$(post /qwen/approve "{\"request_id\":\"$rid\",\"allowed\":true}"); is "approve -> 200" "$(tail -1 <<<"$r")" 200
has "OpenCode got « once »" "$(tail -1 "$ROOT/oc.log")" '"value": "once"'
wait_for "len(d['pending'])" 0 && ok "no longer pending" || bad "still pending"
wait_for "d['history'][0]['source']" appli && ok "history: decided in the app" || bad "history: $(get /qwen/state)"
is "history: allowed" "$(st "d['history'][0]['allowed']")" True
wait_for "len(d['late'])" 1 && ok "the answer after approval is kept for announcing" || bad "no late answer"
is "…and it is the final text" "$(st "d['late'][-1]['text']")" "fait"

say "a decision taken at the keyboard"
echo terminal-approves > "$ROOT/mode"
chat "$TOKEN" "$BODY" >/dev/null
wait_for "d['history'][0]['source']" terminal && ok "history says: terminal" || bad "terminal decision not recorded"
is "…refused" "$(st "d['history'][0]['allowed']")" False

say "Alibaba's filter: same conversation, fallback model"
echo filtered > "$ROOT/mode"
post /qwen/session '{"action":"activate","name":"bureau"}' >/dev/null
r=$(chat "$TOKEN" "$BODY"); a=$(head -n -1 <<<"$r" | answer)
has "says it switched model" "$a" "autre modèle"
has "…and answers" "$a" "Repli : Cinquante-six (bureau)."
has "the retry asked the fallback model" "$(tail -1 "$ROOT/oc.log")" '"modelID": "qwen/qwen3.8-27b"'
has "…of provider openrouter" "$(tail -1 "$ROOT/oc.log")" '"providerID": "openrouter"'

say "provider refuses the request"
echo api-error > "$ROOT/mode"
t0=$(date +%s); r=$(chat "$TOKEN" "$BODY")
has "voice says the provider refused" "$(head -n -1 <<<"$r" | answer)" "fournisseur du modèle a refusé"
[ $(( $(date +%s) - t0 )) -le 2 ] && ok "…right away, not after the timeout" || bad "waited out the timeout"

say "slow turn, then clear, rename, remove"
echo slow > "$ROOT/mode"; before=$(st "len(d['late'])")
t0=$(date +%s); r=$(chat "$TOKEN" "$BODY")
has "voice says it will announce" "$(head -n -1 <<<"$r" | answer)" "annonce"
[ $(( $(date +%s) - t0 )) -le 6 ] && ok "returned within the timeout" || bad "voice hung"
wait_for "len(d['late'])" $((before + 1)) && ok "slow answer kept" || bad "slow answer lost"
is "…final text" "$(st "d['late'][-1]['text']")" "Réponse lente (bureau)."
echo plain > "$ROOT/mode"
old=$(python3 -c "import json;print(json.load(open('$STATE/sessions.json'))['sessions']['bureau'])")
r=$(post /qwen/session '{"action":"clear","name":"bureau"}'); is "clear -> 200" "$(tail -1 <<<"$r")" 200
new=$(python3 -c "import json;print(json.load(open('$STATE/sessions.json'))['sessions']['bureau'])")
[ "$new" != "$old" ] && ok "clear gives a new conversation" || bad "same conversation after clear"
has "…and the window follows it" "$(grep '^bureau|' "$ROOT/windows")" "$new"
r=$(post /qwen/session "{\"action\":\"rename\",\"name\":\"$second\",\"new\":\"essai\"}"); is "rename -> 200" "$(tail -1 <<<"$r")" 200
has "window renamed" "$(cut -d'|' -f1 "$ROOT/windows")" essai
r=$(post /qwen/session '{"action":"remove","name":"essai"}'); is "remove -> 200" "$(tail -1 <<<"$r")" 200
case $(st "d['names']") in *essai*) bad "essai still listed";; *) ok "essai gone";; esac
is "its window is gone" "$(grep -c '^essai|' "$ROOT/windows")" 0
say "restart with a conversation left in an older workdir"
old=$(python3 -c "import json;print(json.load(open('$STATE/sessions.json'))['sessions']['bureau'])")
curl -s -o /dev/null -X PATCH -H "Authorization: $OCAUTH" "http://127.0.0.1:$OCPORT/session/$old" -d '{"directory":"/home/x/qwen"}'
kill "$HUB_PID"; wait "$HUB_PID" 2>/dev/null; start_hub
moved() { python3 -c "import json;print(json.load(open('$STATE/sessions.json'))['sessions']['bureau'])"; }
for _ in $(seq 1 60); do [ "$(moved)" != "$old" ] && break; sleep 0.1; done
new=$(moved)
[ "$new" != "$old" ] && ok "bureau gets a conversation in the current workdir" || bad "still on $old"
has "…its window is re-attached to it" "$(grep '^bureau|' "$ROOT/windows")" "$new"
has "…the old one is kept" "$(curl -s -H "Authorization: $OCAUTH" "http://127.0.0.1:$OCPORT/session")" "$old"
has "…and the log says why" "$(cat "$ROOT/hub.log")" "pas $ROOT"
r=$(chat "$TOKEN" "$BODY"); has "voice answers on it" "$(head -n -1 <<<"$r" | answer)" "Cinquante-six (bureau)."

if grep -q "$TOKEN" "$ROOT/hub.log"; then bad "token in the log"; else ok "token never logged"; fi

printf '\n%d passed, %d failed\n' "$pass" "$failed"; [ "$failed" -eq 0 ]
