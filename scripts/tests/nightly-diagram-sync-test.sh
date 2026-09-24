#!/usr/bin/env bash
# End-to-end harness for nightly-diagram-sync.sh.
#
# The driver derives everything from $HOME — GIT_BASE, the state dir, the
# credential files, and (line 48) PATH itself, which it resets to
# $HOME/.local/bin first. So a fake HOME is enough to own the whole world it
# runs in: repos, remotes, `claude`, `npm`, Kuma, ntfy. The only things not
# already derived are the hardcoded GitHub URLs, which git's
# `url.<base>.insteadOf` rewrites to local bare repos, and the drift-gate URL,
# which reads $KUMA_STATUS.
#
# Nothing here touches the real repos, the real remotes, or the real monitor.
#
#   ./nightly-diagram-sync-test.sh            # all scenarios
#   ./nightly-diagram-sync-test.sh race       # one scenario
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$SCRIPTS/nightly-diagram-sync.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dsync-test.XXXXXX")
# DSYNC_KEEP=1 leaves the fake worlds behind for post-mortem
[ -n "${DSYNC_KEEP:-}" ] && trap 'printf "\nworlds kept: %s\n" "$ROOT"' EXIT \
                         || trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0; only="${1:-}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
# check <description> <regex> — asserts against the captured run output
check() { grep -Eq "$2" "$OUT" && ok "$1" || { bad "$1"; printf '       wanted /%s/\n' "$2"; }; }
nocheck() { grep -Eq "$2" "$OUT" && { bad "$1"; printf '       did NOT want /%s/\n' "$2"; } || ok "$1"; }
# kuma_was <up|down> — did the driver actually push that status to the monitor?
# This is the honesty assertion: every scenario must reach the monitor, and
# with the right verdict. A silent night is the bug we are testing for.
kuma_was() { grep -q "GET /push?status=$1" "$KUMA_LOG" 2>/dev/null; }

# --------------------------------------------------------------------------
# A world the driver can run in
# --------------------------------------------------------------------------
# $1 = home dir to build. Creates bare "remotes" + working clones for the 4
# private repos, net-cfgs, the 4 public snapshots and the site.
build_world() {
  local H="$1" r
  export HOME="$H"
  mkdir -p "$H/git/ludorl82" "$H/remotes" "$H/.local/bin" "$H/.config"

  gitq() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

  for r in nixos-iac k3s-iac cloud-01-iac cloudflare-iac net-cfgs; do
    git init -q --bare "$H/remotes/$r.git"
    git clone -q "$H/remotes/$r.git" "$H/git/ludorl82/$r" 2>/dev/null
    echo "seed" > "$H/git/ludorl82/$r/README.md"
    gitq "$H/git/ludorl82/$r" add README.md
    gitq "$H/git/ludorl82/$r" commit -qm seed
    gitq "$H/git/ludorl82/$r" push -q origin HEAD:cp-1
    gitq "$H/git/ludorl82/$r" branch -q --set-upstream-to=origin/cp-1 cp-1 2>/dev/null
  done
  # the docs the private sessions reconcile. physical-layout.md names the one
  # fixture model on purpose: emit-fleet's check_racked refuses a racked device
  # whose model the doc does not mention, which is the whole point of that gate
  # — the two inventories must not drift apart.
  echo "# network-diagram.md" > "$H/git/ludorl82/net-cfgs/network-diagram.md"
  printf '# physical-layout.md\n\nrack-a, U1 : commutateur Netgear GS348.\n' \
    > "$H/git/ludorl82/net-cfgs/physical-layout.md"
  # emit-fleet cross-checks nixos-iac/hosts/ against the iacDeclared devices and
  # refuses outright when the directory is absent. An empty one is a valid world:
  # no declared hosts, no iacDeclared devices, the two sets agree.
  mkdir -p "$H/git/ludorl82/nixos-iac/hosts"
  : > "$H/git/ludorl82/nixos-iac/hosts/.keep"
  # The seed's durable source. It stopped being an LLM deliverable on
  # 2026-08-19 — emit-fleet.py validates and copies this file instead — and
  # the fake world was never given one, so the seed failed here for a missing
  # input rather than for anything under test. One racked, undeclared device
  # is enough: emit-fleet's declared-half gate compares `hosts/*` against the
  # `iacDeclared: true` names, and this world has neither.
  cat > "$H/git/ludorl82/net-cfgs/fleet.json" <<'JSON'
{
  "fleetVersion": 1,
  "devices": [
    {
      "name": "sw-01",
      "class": "switch",
      "network": "vlan10",
      "role": "commutateur de la baie",
      "iacDeclared": false,
      "location": "rack-a",
      "rackOrder": 1,
      "model": "Netgear GS348"
    }
  ]
}
JSON
  gitq "$H/git/ludorl82/net-cfgs" add -A
  gitq "$H/git/ludorl82/net-cfgs" commit -qm docs
  gitq "$H/git/ludorl82/net-cfgs" push -q

  # the prompts the driver feeds to `claude`
  mkdir -p "$H/git/ludorl82/nixos-iac/scripts/prompts"
  for p in network-diagram-sync.md physical-layout-sync.md fleet-seed.md; do
    echo "prompt $p" > "$H/git/ludorl82/nixos-iac/scripts/prompts/$p"
  done

  # The seed calls a REAL script by path — emit-fleet.py, with host-map.env
  # beside it — rather than a stub on PATH. This world stopped shipping them
  # when that step was added, so the driver refused the seed for a missing
  # file and eight assertions across four scenarios went red for a reason
  # that had nothing to do with what they were testing. Copy the real ones:
  # they are deterministic, they read only what this world contains, and a
  # stub would have hidden the very gate the seed exists to exercise.
  cp "$SCRIPTS/emit-fleet.py" "$SCRIPTS/host-map.env" \
     "$H/git/ludorl82/nixos-iac/scripts/"
  gitq "$H/git/ludorl82/nixos-iac" add -A
  gitq "$H/git/ludorl82/nixos-iac" commit -qm prompts
  gitq "$H/git/ludorl82/nixos-iac" push -q

  # public snapshots
  for r in nixos-iac-public k3s-iac-public cloud-01-iac-public cloudflare-iac-public; do
    git init -q --bare "$H/remotes/$r.git"
    local t="$ROOT/mk-$r"; rm -rf "$t"; git clone -q "$H/remotes/$r.git" "$t" 2>/dev/null
    echo '{"nodes":[]}' > "$t/topology.json"
    gitq "$t" add -A; gitq "$t" commit -qm seed; gitq "$t" push -q origin HEAD:cp-1
  done

  # the site, on dev
  git init -q --bare "$H/remotes/labodeludo.dev.git"
  local s="$ROOT/mk-site"; rm -rf "$s"; git clone -q "$H/remotes/labodeludo.dev.git" "$s" 2>/dev/null
  mkdir -p "$s/src/components" "$s/src/data" "$s/scripts/topology/prompts"
  echo "prompt arch" > "$s/scripts/topology/prompts/arch-diagram.md"
  echo "prompt rack" > "$s/scripts/topology/prompts/rack-diagram.md"
  { echo '<svg>'; for i in $(seq 1 12); do echo "  <g data-node=\"n$i\"></g>"; done; echo '</svg>'; } \
    > "$s/src/components/LiveArchDiagram.astro"
  echo '<svg>{fleet.devices.map(d => d)}</svg>' > "$s/src/components/RackDiagram.astro"
  echo '{"devices":[{"name":"x"}]}' > "$s/src/data/fleet.json"
  echo '{}' > "$s/src/data/architecture.json"
  cat > "$s/scripts/topology/join-topology.py" <<'PY'
import sys, json, pathlib
# regenerates architecture.json — the unstaged byproduct that made every push
# race look like a content conflict before rebase.autoStash
pathlib.Path(sys.argv[2]).write_text(json.dumps({"generated": "now", "nodes": []}) + "\n")
print("join-topology: fixture ->", sys.argv[2])
PY
  cat > "$s/scripts/topology/scan-public.py" <<'PY'
import sys
print(f"scan-public: {len(sys.argv)-1} file(s) clean")
sys.exit(0)
PY
  # The structural delta. $DELTA_MODE=skip-D says the racks' inputs did not
  # move; anything else reports one fixture change per component, so the
  # existing scenarios keep both sessions running as before.
  cat > "$s/scripts/topology/diagram-delta.py" <<'PY'
import json, os, sys
a = sys.argv
comp, out = a[a.index("--component") + 1], a[a.index("--out") + 1]
skip = os.environ.get("DELTA_MODE", "") == f"skip-{comp}"
json.dump({"component": comp, "base": "fixture", "empty": skip, "skip": skip,
           "changes": [] if skip else [f"fixture change for {comp}"]}, open(out, "w"))
PY
  # The lint. $LINT_MODE=fail-B|fail-D refuses that component with a rule id,
  # the way the real one reports.
  cat > "$s/scripts/check-diagram-lint.mjs" <<'JS'
const c = process.argv[2];
if (process.env.LINT_MODE === `fail-${c}`) {
  console.error(`check-diagram-lint ${c}: refused\n  - G2 fixture refusal`);
  process.exit(1);
}
console.log(`check-diagram-lint ${c}: ok`);
JS
  # gpu-01's search index: tracked, rebuilt by the build a session may run, and
  # committed by the driver. $VECT_MODE=down makes the rebuild fail (embedder
  # unreachable), =empty makes it produce a file with no chunks.
  mkdir -p "$s/public"
  echo '{"model":"bge-m3","dim":4,"generated":"seed","chunks":[{"h":"a","v":[0,0,0,1]}]}' \
    > "$s/public/gpu-01-vectors.json"
  cat > "$s/scripts/build-gpu-01-vectors.mjs" <<'JS'
import fs from "node:fs";
const OUT = "public/gpu-01-vectors.json";
if (process.env.VECT_MODE === "down") {
  console.error("bge-m3 unreachable"); process.exit(1);
}
const d = process.env.VECT_MODE === "empty"
  ? { model: "bge-m3", dim: 4, generated: "rebuilt", chunks: [] }
  : { model: "bge-m3", dim: 4, generated: "rebuilt",
      chunks: [{ h: "a", v: [0, 0, 0, 1] }, { h: "b", v: [1, 0, 0, 0] }] };
fs.writeFileSync(OUT, JSON.stringify(d) + "\n");
console.log(`écrit ${OUT} — ${d.chunks.length} tronçons, 4 dimensions, 0.00 Mo`);
JS
  echo "node_modules/" > "$s/.gitignore"
  gitq "$s" add -A; gitq "$s" commit -qm seed; gitq "$s" push -q origin HEAD:dev
  # the driver reads the published seed here to decide if the seed ever ran
  git clone -q --branch dev "$H/remotes/labodeludo.dev.git" "$H/git/ludorl82/labodeludo.dev" 2>/dev/null

  # rewrite the driver's hardcoded GitHub URLs to our bare repos
  git config --global --replace-all url."$H/remotes/".insteadOf "https://github.com/ludorl82/"
  git config --global --add url."$H/remotes/".insteadOf "git@github.com:ludorl82/"
  git config --global init.defaultBranch cp-1
  git config --global user.email t@t
  git config --global user.name t

  # A real listener, so we can read the status= the driver actually pushed.
  # (file:// cannot work here — the driver GETs the URL, it does not write it.)
  KUMA_LOG="$H/kuma-requests.log"
  # banner (port) goes to stdout, request lines to stderr — capture both
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$H" >"$KUMA_LOG" 2>&1 &
  KUMA_PID=$!
  local port=""
  for _ in $(seq 1 50); do
    port=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$KUMA_LOG" 2>/dev/null | head -1)
    [ -n "$port" ] && break
    sleep 0.1
  done
  [ -n "$port" ] || { echo "FATAL: no Kuma stub port"; exit 1; }
  echo "http://127.0.0.1:$port/push" > "$H/.config/kuma-diagram-sync-push"
}

# Stub `claude`. $CLAUDE_MODE decides what the "sessions" do.
install_stubs() {
  local H="$HOME"
  cat > "$H/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Which session is this? The driver passes the prompt as one argument.
mode="${CLAUDE_MODE:-normal}"
prompt="$*"
case "$prompt" in
  *"prompt network-diagram-sync.md"*) sess=A ;;
  *"prompt physical-layout-sync.md"*) sess=C ;;
  *"prompt fleet-seed.md"*)           sess=SEED ;;
  *"prompt arch"*)                    sess=B ;;
  *"prompt rack"*)                    sess=D ;;
  *)                                  sess=? ;;
esac
echo "[stub claude: session $sess, mode $mode]"
# every prompt a session received, so a scenario can assert what it was told
printf '=== %s\n%s\n' "$sess" "$prompt" >> "$HOME/claude-prompts.log"
[ "$mode" = "fail-$sess" ] && exit 1
[ "$mode" = "slow-$sess" ] && sleep 4
case "$sess" in
  # RELATIVE paths, like the real prompts say since 2026-09-16: A and C run in a
  # private view whose net-cfgs is a worktree, and an absolute $GIT/net-cfgs
  # would write the shared checkout the driver no longer commits from.
  A) echo "reconciled" >> net-cfgs/network-diagram.md
     [ "$mode" = "stray" ] && echo "oops" >> net-cfgs/physical-layout.md
     # the one way a session could still reach the shared checkout
     [ "$mode" = "escape" ] && echo "meddled" >> "$GIT/net-cfgs/network-diagram.md" ;;
  C) echo "reconciled" >> net-cfgs/physical-layout.md ;;
  # SEED is no longer an LLM session at all — emit-fleet.py replaced it on
  # 2026-08-19 and reads net-cfgs/fleet.json, which build_world now ships.
  # The branch stays so an unexpected seed session is still labelled rather
  # than falling through to `?`.
  SEED) : ;;
  B) f=site/src/components/LiveArchDiagram.astro
     [ -f "$f" ] || f=src/components/LiveArchDiagram.astro
     if [ "$mode" = "strip-interactivity" ]; then echo '<svg>bare</svg>' > "$f"
     else { echo '<svg>redrawn'; for i in $(seq 1 12); do echo "  <g data-node=\"n$i\"></g>"; done; echo '</svg>'; } > "$f"; fi ;;
  D) echo '<svg>racks redrawn {fleet.devices.map(d => d)}</svg>' > src/components/RackDiagram.astro
     # the 2026-08-08 case: a scratch file the sandbox would not let it delete
     [ "$mode" = "byproduct" ] && echo "// scratch" > .rack-layout-check.mjs
     # a genuinely alarming stray: a TRACKED file outside the deliverable set
     [ "$mode" = "tracked-stray" ] && echo "meddled" >> .gitignore
     # what `npm run build` does to the tracked search index inside a session
     if [ "$mode" = "vectors" ]; then
       for f in public/gpu-01-vectors.json site/public/gpu-01-vectors.json; do
         [ -f "$f" ] && echo '{"model":"bge-m3","dim":4,"generated":"by the session","chunks":[]}' > "$f"
       done
     fi ;;
esac
exit 0
STUB
  chmod +x "$H/.local/bin/claude"

  # Stub `qwen` — the default author since 2026-09-13. It hands the prompt to
  # the claude stub above, so every scenario exercises the same fake sessions
  # whichever backend the driver picks; only the harness-specific parts are
  # its own: a `-o json` result on stdout, a usage-ledger line (what the
  # driver prices the night from), and $QWEN_MODE=turns to end with exit 53
  # the way Qwen Code does at --max-session-turns. With --openai-logging-dir it
# writes one request log per call, the shape Qwen Code 0.23 writes; the
# ordinary one quotes the filter's code in its REQUEST text, as a session
# reading this driver would, so keeping it would mean the error field was not
# what got judged. $QWEN_MODE=refuse ends every call the way the content
# filter did on 2026-09-16 (exit 0, marker in the transcript, error in the
# log); refuse-once does that to the first call only.
  cat > "$H/.local/bin/qwen" <<'STUB'
#!/usr/bin/env bash
prompt=""; logdir=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift;; --openai-logging-dir) logdir="$2"; shift;; esac; shift; done
mkdir -p "$HOME/.qwen"
echo '{"models":{"qwen3.8-flash":{"requests":3,"inputTokens":600000,"outputTokens":9000,"cachedTokens":540000}}}' >> "$HOME/.qwen/usage_record.jsonl"
[ "${QWEN_MODE:-}" = turns ] && { echo '[{"type":"result","result":"Reached max turns"}]'; exit 53; }
if [ -n "$logdir" ]; then
  mkdir -p "$logdir"
  echo '{"request":{"messages":[{"role":"tool","content":"grep DataInspectionFailed"}]},"response":{},"error":null}' > "$logdir/openai-1-ok.json"
fi
refuse=""
case "${QWEN_MODE:-}" in
  refuse) refuse=1;;
  refuse-once) [ -e "$REAL_HOME/.refused-once" ] || { refuse=1; touch "$REAL_HOME/.refused-once"; };;
esac
if [ -n "$refuse" ]; then
  [ -n "$logdir" ] && echo '{"request":{"messages":[]},"response":null,"error":{"message":"400 <400> InternalError.Algo.DataInspectionFailed: Input text data may contain inappropriate content."}}' > "$logdir/openai-2-refused.json"
  echo '[{"type":"result","result":"[API Error: 400 <400> InternalError.Algo.DataInspectionFailed: Input text data may contain inappropriate content.]"}]'
  exit 0
fi
HOME="$REAL_HOME" "$REAL_HOME/.local/bin/claude" -p "$prompt" >&2; rc=$?
echo '[{"type":"result","result":"[stub qwen] rien à signaler"}]'
exit $rc
STUB
  chmod +x "$H/.local/bin/qwen"
  # No KeePass from the fake world: the driver's key lookup goes through ssh,
  # and the no-key scenario must see that fail rather than fetch a real key
  # (it did, once — the test quietly used production credentials).
  printf '#!/usr/bin/env bash\necho "stub ssh: no remote in the test world" >&2; exit 255\n' > "$H/.local/bin/ssh"
  chmod +x "$H/.local/bin/ssh"

  cat > "$H/.local/bin/npm" <<'STUB'
#!/usr/bin/env bash
[ "${NPM_MODE:-ok}" = "fail" ] && { echo "npm: build failed"; exit 1; }
echo "[stub npm $*]"; exit 0
STUB
  chmod +x "$H/.local/bin/npm"

  # the driver resets PATH to $HOME/.local/bin first, then system dirs; real
  # git/python3/curl still resolve there. Symlink anything unusual if needed.
  for t in git python3 curl mktemp date comm awk grep sed tr head; do
    command -v "$t" >/dev/null || echo "WARNING: $t missing"
  done
}

# A green drift gate served from a file:// URL the gate's urllib can read.
write_gate() { # write_gate <green|red>
  local now; now=$(date -u +"%Y-%m-%d %H:%M:%S")
  local status=1; [ "$1" = red ] && status=0
  printf '{"heartbeatList":{"1":[{"status":%s,"time":"%s"}]}}' "$status" "$now" \
    > "$HOME/gate.json"
  export KUMA_STATUS="file://$HOME/gate.json"
}

# run_driver <label> [env assignments...] — captures output to $OUT
run_driver() {
  OUT="$ROOT/out.$1"; shift
  # The driver hands the qwen stub a private HOME ($HOME/.config/qwen-pipeline);
  # REAL_HOME is how the stub finds the claude stub again from in there. A fake
  # key keeps the driver off KeePass.
  ( export GIT="$HOME/git/ludorl82" REAL_HOME="$HOME" QWEN_API_KEY="stub-key" \
           FLEET_OUT_FILE="$HOME/.cache/nightly-diagram-sync/fleet.json" \
           FLEET_SCRATCH_DIR="$HOME/git/ludorl82/.diagram-scratch"
    mkdir -p "$(dirname "$FLEET_OUT_FILE")"
    env "$@" bash "$DRIVER" ) > "$OUT" 2>&1
  RC=$?
  printf '  (exit %s)\n' "$RC"
}

# fresh <name> — a brand-new world, stubs installed, gate green
fresh() {
  [ -n "${KUMA_PID:-}" ] && kill "$KUMA_PID" 2>/dev/null; KUMA_PID=""
  local H="$ROOT/home-$1"; rm -rf "$H"
  build_world "$H" >"$ROOT/build.$1.log" 2>&1 || { echo "world build FAILED, see $ROOT/build.$1.log"; exit 1; }
  install_stubs
  write_gate green
}

want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

# --------------------------------------------------------------------------
# Scenarios
# --------------------------------------------------------------------------
if want happy; then
  say "happy path: everything moved, everything lands"
  fresh happy
  run_driver happy
  check "session A committed"            'A: network-diagram\.md reconciled'
  check "session C committed"            'C: physical-layout\.md reconciled'
  check "seed passed both gates"         'seed: fleet\.json passed both gates'
  check "B redrew"                       'B: architecture redrawn'
  check "D redrew"                       'D: racks redrawn'
  check "B/D pushed"                     'B/D: pushed'
  check "a change is notified"           'skipping notify: Nightly diagram sync$'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  kuma_was up   && ok "Kuma pushed UP"   || bad "Kuma pushed UP"
  # the real assertions: did the work actually reach the remotes?
  git -C "$HOME/remotes/net-cfgs.git" log --oneline -1 2>/dev/null | grep -q reconcile \
    && ok "net-cfgs remote advanced" || bad "net-cfgs remote advanced"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/components/LiveArchDiagram.astro 2>/dev/null \
    | grep -q redrawn && ok "site remote has the redraw" || bad "site remote has the redraw"
  # the delta reached the sessions, each its own
  grep -A20 '^=== B$' "$HOME/claude-prompts.log" | grep -q 'fixture change for B' \
    && ok "B was told what moved" || bad "B was told what moved"
  grep -A20 '^=== D$' "$HOME/claude-prompts.log" | grep -q 'fixture change for D' \
    && ok "D was told what moved" || bad "D was told what moved"
fi

if want lint; then
  say "the lint refuses B: nothing lands, the work is kept, the night is red"
  fresh lint
  run_driver lint LINT_MODE=fail-B
  check "refusal reported with its rule"  'B: REFUSED by check-diagram-lint \(G2\)'
  check "deliverables were rescued"       'deliverables saved to .*lint-B-'
  nocheck "nothing pushed"                'B/D: pushed'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/components/LiveArchDiagram.astro 2>/dev/null \
    | grep -q redrawn && bad "the refused redraw must NOT be on the remote" \
    || ok "the refused redraw never reached the remote"
fi

if want lint-missing; then
  say "the site has no lint: fail closed, not open"
  fresh lintmissing
  git -C "$ROOT/mk-site" rm -q scripts/check-diagram-lint.mjs
  git -C "$ROOT/mk-site" -c user.email=t@t -c user.name=t commit -qm "no lint"
  git -C "$ROOT/mk-site" push -q origin HEAD:dev
  run_driver lintmissing
  check "refused for the missing checker" 'REFUSED by check-diagram-lint'
  nocheck "nothing pushed"                'B/D: pushed'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
fi

if want rack-skip; then
  say "the racks' inputs did not move: no D session, B still runs"
  fresh rackskip
  run_driver rackskip DELTA_MODE=skip-D
  check "D skipped, and said why"   'D: fleet unchanged since the last rack drawing — no session'
  check "B still redrew"            'B: architecture redrawn'
  check "and it landed"             'B/D: pushed'
  nocheck "no misleading D verdict" 'D: racks (redrawn|already matched)'
  grep -q '^=== D$' "$HOME/claude-prompts.log" 2>/dev/null \
    && bad "no D session was started" || ok "no D session was started"
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  kuma_was up && ok "Kuma pushed UP" || bad "Kuma pushed UP"
fi

if want author-claude; then
  say "DIAGRAM_AUTHOR=claude: the Claude Code path still works end to end"
  fresh authorclaude
  run_driver authorclaude DIAGRAM_AUTHOR=claude
  check "B redrew"                   'B: architecture redrawn'
  nocheck "no cost line for claude"  'cost: .* USD'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  git -C "$HOME/remotes/net-cfgs.git" log -1 --format=%B 2>/dev/null | grep -q 'Co-Authored-By: Claude Opus 5' \
    && ok "commit trailer names Claude" || bad "commit trailer names Claude"
fi

if want qwen-cost; then
  say "qwen author: the night is priced from the ledger, commits name the model"
  fresh qwencost
  run_driver qwencost
  check "cost line in the summary"   'cost: [0-9.]+ USD on qwen3.8-flash'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  git -C "$HOME/remotes/labodeludo.dev.git" log -1 --format=%B dev 2>/dev/null | grep -q 'qwen3.8-flash via Qwen Code' \
    && ok "site commit trailer names the model" || bad "site commit trailer names the model"
  [ -f "$HOME/.config/qwen-pipeline/.qwen/settings.json" ] && ok "pipeline got its own Qwen Code HOME" || bad "pipeline got its own Qwen Code HOME"
fi

if want qwen-turns; then
  say "qwen author hits its turn ceiling: labelled, red, nothing pushed"
  fresh qwenturns
  run_driver qwenturns QWEN_MODE=turns
  check "ceiling reported"          'hit the turn ceiling'
  check "session failure labelled"  'A: qwen session failed \(exit 53\)'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
fi

if want qwen-refuse-once; then
  say "the content filter refuses A once: saved, retried from a clean tree, lands"
  fresh refuseonce
  run_driver refuseonce QWEN_MODE=refuse-once
  st="$HOME/.local/state/nightly-diagram-sync"
  check "the refusal is detected"      'A: the API refused this session'
  check "one retry is announced"       'A: refused by the API — one more try'
  check "the retry lands and says so"  'A: network-diagram\.md reconciled \([0-9a-f]+, [a-z]+, after one API refusal\)'
  check "C untouched by A's refusal"   'C: physical-layout\.md reconciled'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  n=$(ls "$st/refused" 2>/dev/null | wc -l)
  [ "$n" = 1 ] && ok "exactly the refused request is kept" || bad "exactly the refused request is kept (got $n)"
  ls "$st/refused" 2>/dev/null | grep -q '^A-.*refused\.json$' \
    && ok "kept under the session's name" || bad "kept under the session's name"
  [ "$(stat -c %a "$st/refused")" = 700 ] && ok "refused/ is 0700" || bad "refused/ is 0700"
  [ -z "$(ls -A "$st/requests" 2>/dev/null)" ] \
    && ok "every other request log is deleted" || bad "every other request log is deleted"
fi

if want qwen-refuse-twice; then
  say "the content filter refuses A twice: red, base not banked"
  fresh refusetwice
  run_driver refusetwice QWEN_MODE=refuse
  st="$HOME/.local/state/nightly-diagram-sync"
  check "one retry, not more"          'A: refused by the API — one more try'
  [ "$(grep -c 'A: refused by the API — one more try' "$OUT")" = 1 ] \
    && ok "exactly one retry" || bad "exactly one retry"
  check "A fails with the refusal code" 'A: qwen session failed \(exit 60\)'
  [ ! -s "$st/seen-A" ] && ok "A's base is not advanced" || bad "A's base is not advanced"
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  n=$(ls "$st/refused" 2>/dev/null | grep -c '^A-')
  [ "$n" = 2 ] && ok "both refused requests are kept" || bad "both refused requests are kept (got $n)"
fi

if want no-key; then
  say "qwen author without a key: refuses before any session"
  fresh nokey
  OUT="$ROOT/out.nokey"
  ( export GIT="$HOME/git/ludorl82" REAL_HOME="$HOME" QWEN_API_KEY="" ; bash "$DRIVER" ) > "$OUT" 2>&1; RC=$?
  check "says what is missing" 'no Model Studio API key'
  [ "$RC" != 0 ] && ok "non-zero exit" || bad "non-zero exit"
  nocheck "no session started" 'stub claude: session'
fi

if want skip; then
  say "no input moved: the whole run is skipped"
  fresh skip
  run_driver skip1 >/dev/null
  run_driver skip2
  check "second run skips"  'no input changed since last run'
  nocheck "a quiet night sends nothing" 'skipping notify'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
fi

if want race; then
  say "push race on dev: rebase, retry, land (the 2026-08-08 failure)"
  fresh race
  # a competing commit lands on dev while the driver is mid-run: the stub
  # pushes it from inside session B, which is exactly when the real one hit
  cat > "$HOME/.local/bin/claude.race" <<'STUB'
#!/usr/bin/env bash
t=$(mktemp -d); git clone -q --branch dev "$HOME/remotes/labodeludo.dev.git" "$t/s" 2>/dev/null
echo "meanwhile" > "$t/s/src/content-new.md"
git -C "$t/s" add -A
git -C "$t/s" -c user.email=t@t -c user.name=t commit -qm "someone else pushed"
git -C "$t/s" push -q origin dev; rm -rf "$t"
STUB
  chmod +x "$HOME/.local/bin/claude.race"
  # wrap the stub so session B triggers the competing push first
  mv "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.real"
  cat > "$HOME/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"prompt arch"*) "$HOME/.local/bin/claude.race" ;; esac
exec "$HOME/.local/bin/claude.real" "$@"
STUB
  chmod +x "$HOME/.local/bin/claude"
  run_driver race
  check "the race was detected and rebased" 'push race on origin/dev — rebased, retrying'
  check "and the push then landed"          'B/D: pushed'
  nocheck "no bogus conflict report"        'conflicts with the remote'
  nocheck "nothing was discarded"           'DISCARDED|FAILED to push'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/components/LiveArchDiagram.astro 2>/dev/null \
    | grep -q redrawn && ok "redraw survived the race" || bad "redraw survived the race"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/content-new.md >/dev/null 2>&1 \
    && ok "the other commit survived too" || bad "the other commit survived too"
fi

if want conflict; then
  say "genuine conflict: refuse, rescue the commit, report down"
  fresh conflict
  mv "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.real"
  cat > "$HOME/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
# push a conflicting edit to the SAME file session B is about to redraw
case "$*" in *"prompt arch"*)
  t=$(mktemp -d); git clone -q --branch dev "$HOME/remotes/labodeludo.dev.git" "$t/s" 2>/dev/null
  echo '<svg>theirs</svg>' > "$t/s/src/components/LiveArchDiagram.astro"
  git -C "$t/s" add -A
  git -C "$t/s" -c user.email=t@t -c user.name=t commit -qm "conflicting redraw"
  git -C "$t/s" push -q origin dev; rm -rf "$t" ;;
esac
exec "$HOME/.local/bin/claude.real" "$@"
STUB
  chmod +x "$HOME/.local/bin/claude"
  run_driver conflict
  check "conflict detected, not resolved"  'conflicts with the remote — not resolving'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  check "the commit was rescued"           'FAILED to push — commit rescued'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  b=$(ls "$HOME/.local/state/nightly-diagram-sync/rescue/"*.bundle 2>/dev/null | head -1)
  if [ -n "$b" ]; then
    ok "rescue bundle exists"
    t="$ROOT/recover"; rm -rf "$t"
    git clone -q --branch dev "$HOME/remotes/labodeludo.dev.git" "$t" 2>/dev/null
    if git -C "$t" fetch -q "$b" 2>/dev/null && \
       git -C "$t" show FETCH_HEAD:src/components/LiveArchDiagram.astro 2>/dev/null | grep -q redrawn
    then ok "the lost redraw is recoverable from the bundle"
    else bad "the lost redraw is recoverable from the bundle"; fi
  else bad "rescue bundle exists"; fi
fi

if want session-fail; then
  say "a session fails: reported, and the night is red"
  fresh sessionfail
  run_driver sessfail CLAUDE_MODE=fail-A
  check "A reported as failed" 'A: (claude|qwen) session failed'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  check "C still ran"          'C: physical-layout\.md reconciled'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
fi

if want stray; then
  say "a session touches a file it shouldn't: nothing is committed"
  fresh stray
  run_driver stray CLAUDE_MODE=stray
  check "stray files refused"   'A: FAILED \(unexpected files'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  nocheck "nothing committed"   'A: network-diagram\.md reconciled'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
fi

if want interactivity; then
  say "B strips the click targets: the gate catches it"
  fresh interactivity
  run_driver interact CLAUDE_MODE=strip-interactivity
  check "interactivity contract enforced" 'B: FAILED interactivity contract'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/components/LiveArchDiagram.astro 2>/dev/null \
    | grep -q bare && bad "the stripped file must NOT be on the remote" \
    || ok "the stripped file never reached the remote"
fi

if want build-fail; then
  say "the build fails: nothing is pushed"
  fresh buildfail
  run_driver buildfail NPM_MODE=fail
  check "build failure reported" 'B/D: FAILED build'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  nocheck "nothing pushed"       'B/D: pushed'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
fi

if want gate-red; then
  say "drift gate red: the private sessions do not run"
  fresh gatered
  write_gate red
  run_driver gatered
  check "A skipped on the gate" 'A: skipped \(not-green'
  check "C skipped on the gate" 'C: skipped \(not-green'
  nocheck "A did not commit"    'A: network-diagram\.md reconciled'
  # the test world has no ntfy token, so notify logs the title it would send
  check "the skip is notified, titled as a skip" 'skipping notify: Nightly diagram sync: A/C skipped \(drift gate\)'
  nocheck "and not as an ordinary summary"      'skipping notify: Nightly diagram sync$'
fi

if want vectors; then
  say "the search index: a session's copy is discarded, the driver's is committed"
  fresh vectors
  run_driver vectors CLAUDE_MODE=vectors
  nocheck "the guard did not fire on it" 'unexpected files'
  check "B still redrew"                 'B: architecture redrawn'
  check "D still redrew"                 'D: racks redrawn'
  check "the driver rebuilt the index"   'index: écrit public/gpu-01-vectors\.json — 2 tronçons'
  check "and committed it"               'index: gpu-01-vectors\.json refreshed'
  check "it all landed"                  'B/D: pushed'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  v=$(git -C "$HOME/remotes/labodeludo.dev.git" show dev:public/gpu-01-vectors.json)
  case "$v" in *'"generated":"rebuilt"'*) ok "the remote has the driver's index";;
    *) bad "the remote has the driver's index (got ${v:0:60})";; esac
  case "$v" in *'by the session'*) bad "the session's index must not be published";;
    *) ok "the session's index never reached the remote";; esac
fi

if want vectors-down; then
  say "the embedder is down: the index is left alone, the drawings still land"
  fresh vectorsdown
  run_driver vectorsdown CLAUDE_MODE=vectors VECT_MODE=down
  check "the failure is said"          'could not rebuild public/gpu-01-vectors\.json'
  check "and summarised as not done"   'index: gpu-01-vectors\.json NOT refreshed'
  check "the drawings still landed"    'B/D: pushed'
  [ "$RC" = 0 ] && ok "exit 0 — a stale fallback is not a failed night" || bad "exit 0 (got $RC)"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:public/gpu-01-vectors.json | grep -q '"generated":"seed"' \
    && ok "the committed index is untouched" || bad "the committed index is untouched"
fi

if want vectors-empty; then
  say "the rebuilt index has no chunks: refused, and the old one kept"
  fresh vectorsempty
  run_driver vectorsempty CLAUDE_MODE=vectors VECT_MODE=empty
  check "the refusal is said"        'has no chunks — leaving the committed one alone'
  check "and it fails the run"       'index: FAILED \(rebuilt file unusable\)'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:public/gpu-01-vectors.json | grep -q '"generated":"seed"' \
    && ok "the committed index is untouched" || bad "the committed index is untouched"
fi

if want death; then
  say "the driver dies unexpectedly: the monitor still hears about it"
  fresh death
  # make a mid-run command explode: remove a private repo after the heads scan
  cat > "$HOME/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"prompt network-diagram-sync.md"*) rm -rf "$HOME/git/ludorl82/net-cfgs/.git" ;; esac
exit 0
STUB
  chmod +x "$HOME/.local/bin/claude"
  run_driver death
  check "the death was reported to Kuma" 'driver died \(exit'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  [ "$RC" != 0 ] && ok "non-zero exit" || bad "non-zero exit (got $RC)"
fi

if want byproduct; then
  say "a session leaves an undeletable scratch file: swept, not fatal"
  fresh byproduct
  run_driver byproduct CLAUDE_MODE=byproduct
  check "the byproduct was swept"  'swept session scratch files.*rack-layout-check\.mjs'
  check "B still redrew"           'B: architecture redrawn'
  check "D still redrew"           'D: racks redrawn'
  check "and it all landed"        'B/D: pushed'
  nocheck "the guard did not fire" 'unexpected files'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  kuma_was up && ok "Kuma pushed UP" || bad "Kuma pushed UP"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:.rack-layout-check.mjs >/dev/null 2>&1 \
    && bad "the scratch file must NOT be on the remote" || ok "the scratch file never reached the remote"
fi

if want tracked-stray; then
  say "a session edits a tracked file it shouldn't: refuse, but keep the work"
  fresh trackedstray
  run_driver trackedstray CLAUDE_MODE=tracked-stray
  check "the real guard still fires" 'FAILED \(unexpected files'
  check "deliverables were rescued"  'deliverables saved to'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  pt=$(ls "$HOME/.local/state/nightly-diagram-sync/rescue/"stray-refusal-*.patch 2>/dev/null | head -1)
  if [ -n "$pt" ]; then
    ok "rescue patch exists"
    t="$ROOT/recover-patch"; rm -rf "$t"
    git clone -q --branch dev "$HOME/remotes/labodeludo.dev.git" "$t" 2>/dev/null
    if git -C "$t" apply "$pt" 2>/dev/null && grep -q redrawn "$t/src/components/LiveArchDiagram.astro"; then
      ok "the refused redraw re-applies cleanly"
    else bad "the refused redraw re-applies cleanly"; fi
  else bad "rescue patch exists"; fi
fi

# --------------------------------------------------------------------------
# Resilience (2026-09-16). On that day the cronicle Deployment was updated
# mid-run, the ssh that carried the job died with the old pod, and SIGHUP took
# the driver down between C and B — no Cronicle record, no Kuma heartbeat, and
# C's half-written prose left in the shared net-cfgs checkout, which then made
# the next two runs reconcile against a stale copy. Each scenario below
# replays one part of that.
# --------------------------------------------------------------------------
if want detach; then
  say "the follower dies mid-run: the run itself finishes and reports"
  fresh detach
  st="$HOME/.local/state/nightly-diagram-sync"
  OUT="$ROOT/out.detach"
  # The follower gets its own process group so the test can HUP exactly what
  # the ssh session would have taken with it — the follower and its tail —
  # and nothing else.
  ( export GIT="$HOME/git/ludorl82" REAL_HOME="$HOME" QWEN_API_KEY="stub-key" CLAUDE_MODE=slow-A
    setsid bash -c 'echo $$ > "$HOME/follower.pid"; exec bash "$1"' _ "$DRIVER" ) > "$OUT" 2>&1 &
  for _ in $(seq 1 50); do [ -s "$HOME/follower.pid" ] && break; sleep 0.1; done
  sleep 2   # inside session A's four-second nap
  kill -HUP -- "-$(cat "$HOME/follower.pid")" 2>/dev/null
  # the run left behind must still finish on its own
  rcf=""
  for _ in $(seq 1 300); do
    rcf=$(ls "$st"/../jobs/nightly-diagram-sync/*.rc 2>/dev/null | head -1); [ -n "$rcf" ] && break; sleep 0.1
  done
  [ -n "$rcf" ] && ok "the orphaned run recorded an exit code" || bad "the orphaned run recorded an exit code"
  [ "$(cat "$rcf" 2>/dev/null)" = 0 ] && ok "and it was 0" || bad "and it was 0 (got $(cat "$rcf" 2>/dev/null))"
  git -C "$HOME/remotes/net-cfgs.git" log --oneline -1 2>/dev/null | grep -q reconcile \
    && ok "A's reconcile still reached the remote" || bad "A's reconcile still reached the remote"
  kuma_was up && ok "and it pushed its own heartbeat" || bad "and it pushed its own heartbeat"
  [ ! -e "$st/in-flight" ] && ok "a clean end cleared the in-flight marker" || bad "a clean end cleared the in-flight marker"
fi

if want detach-sshd; then
  say "detached under a Cronicle-like sshd environment, with the console's bashrc"
  # Debian's bash reads ~/.bashrc for `bash -c` when SSH_CLIENT is set and SHLVL
  # is low; the console's rc replaces bash with zsh before any guard. The first
  # detach shipped with every test green and never started once in production.
  fresh detachsshd
  printf 'exec true\n' > "$HOME/.bashrc"
  OUT="$ROOT/out.detachsshd"
  ( export GIT="$HOME/git/ludorl82" REAL_HOME="$HOME" QWEN_API_KEY="stub-key"
    env -u SHLVL SSH_CLIENT="198.51.100.1 50000 2222" SSH_CONNECTION="198.51.100.1 50000 198.51.100.2 2222" \
      bash "$DRIVER" < /dev/null ) > "$OUT" 2>&1
  RC=$?
  [ "$RC" = 0 ] && ok "the run started and finished (exit 0)" || bad "the run started and finished (got $RC)"
  check "A still committed" 'A: network-diagram\.md reconciled'
  nocheck "no 'never started'" 'never started'
  rm -f "$HOME/.bashrc"
fi

if want lock; then
  say "a second run while one is in flight does nothing at all"
  fresh lock
  st="$HOME/.local/state/nightly-diagram-sync"; mkdir -p "$st"
  echo "started 2026-09-16T15:43:00Z, pid 4242" > "$st/in-flight"
  ( flock 9; sleep 20 ) 9> "$st/run.lock" &
  holder=$!
  sleep 0.5
  run_driver lock
  check "it says why"                  'another run is still in flight'
  [ "$RC" = 0 ] && ok "exit 0 — not a failure" || bad "exit 0 — not a failure (got $RC)"
  git -C "$HOME/remotes/net-cfgs.git" log --oneline -1 2>/dev/null | grep -q reconcile \
    && bad "it touched net-cfgs anyway" || ok "it touched no repository"
  # the marker belongs to the run holding the lock and must survive
  [ -s "$st/in-flight" ] && ok "the live run's marker is left alone" || bad "the live run's marker is left alone"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
fi

if want orphan; then
  say "a run that vanished is reported by the next one, at once"
  fresh orphan
  st="$HOME/.local/state/nightly-diagram-sync"; mkdir -p "$st"
  echo "started 2026-09-16T15:43:00Z, pid 4242" > "$st/in-flight"
  run_driver orphan
  check "it names the run that vanished" 'never recorded a clean end'
  kuma_was down && ok "Kuma heard it immediately" || bad "Kuma heard it immediately"
  kuma_was up   && ok "and this run still did its own work" || bad "and this run still did its own work"
  [ ! -e "$st/in-flight" ] && ok "and cleared the marker on its clean end" || bad "and cleared the marker on its clean end"
fi

if want worktree; then
  say "sessions never touch the shared net-cfgs checkout"
  fresh worktree
  run_driver worktree
  check "A committed"  'A: network-diagram\.md reconciled'
  check "C committed"  'C: physical-layout\.md reconciled'
  [ -z "$(git -C "$HOME/git/ludorl82/net-cfgs" status --porcelain)" ] \
    && ok "the shared checkout is clean afterwards" || bad "the shared checkout is clean afterwards"
  [ -z "$(ls -A "$HOME/.local/state/nightly-diagram-sync/views" 2>/dev/null)" ] \
    && ok "no view is left behind" || bad "no view is left behind"
  [ "$(git -C "$HOME/git/ludorl82/net-cfgs" worktree list | wc -l)" = 1 ] \
    && ok "no worktree stays registered" || bad "no worktree stays registered"

  say "a session that escapes to the shared checkout is flagged"
  fresh escape
  run_driver escape CLAUDE_MODE=escape
  check "the escape is reported" 'WARNING the shared net-cfgs checkout changed'
fi

if want deadview; then
  say "a view a dead run left behind is rescued, then removed"
  fresh deadview
  st="$HOME/.local/state/nightly-diagram-sync"; mkdir -p "$st/views/A.dead"
  nc="$HOME/git/ludorl82/net-cfgs"
  git -C "$nc" fetch -q origin
  ref=$(git -C "$nc" rev-parse -q --verify origin/cp-1 >/dev/null && echo origin/cp-1 || echo origin/main)
  git -C "$nc" worktree add -q --detach "$st/views/A.dead/net-cfgs" "$ref"
  echo "a dead session's reconcile" >> "$st/views/A.dead/net-cfgs/network-diagram.md"
  run_driver deadview
  check "the rescue is reported"  "a dead run's edit was rescued"
  ls "$st"/rescue/orphan-A-*.patch >/dev/null 2>&1 \
    && ok "its edit is saved as a patch" || bad "its edit is saved as a patch"
  [ ! -d "$st/views/A.dead" ] && ok "the dead view is gone" || bad "the dead view is gone"
fi

printf '\n\033[1m%s passed, %s failed\033[0m\n' "$pass" "$failed"
[ "$failed" = 0 ]
