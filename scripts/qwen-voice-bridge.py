"""Hub des sessions de l'observateur du labo (OpenCode), sur l'hôte console-vm.

OpenCode tourne comme SERVEUR dans le conteneur console (fenêtre tmux
`observateur:gaming-01`, `opencode serve`), et tout le monde lui parle : le terminal
(`opencode attach`, une fenêtre tmux par session), la voix du bureau et
l'application Home Assistant, à travers ce hub. Une session = une
conversation OpenCode ; le manifeste garde nom -> identifiant et la session
ACTIVE, celle de la voix.

API pour Home Assistant (inchangée depuis la version Qwen Code ; jeton en
« Authorization: Bearer ») :
  GET  /qwen/state                      sessions, active, en attente, historique, réponses tardives
  POST /qwen/session  {"action": "add"}
                      {"action": "remove",   "name": n}
                      {"action": "rename",   "name": n, "new": m}
                      {"action": "activate", "name": n}
                      {"action": "clear",    "name": n}   nouvelle conversation
  POST /qwen/approve  {"request_id": id, "allowed": true|false}
et l'API Ollama (/api/tags, /api/chat) pour le pipeline vocal.

La voix n'approuve JAMAIS. Une demande d'autorisation vient d'OpenCode
(permission.asked) ; l'application y répond par POST /permission/<id>/reply,
le terminal par son propre écran, et l'historique dit qui a tranché.

Filtre de contenu : si un modèle de repli est configuré (QWEN_FALLBACK_MODEL),
un tour refusé (DataInspectionFailed, le filtre d'Alibaba) lui est reposé
dans la même conversation. Muse, le modèle par défaut depuis le 2026-09-27,
n'a pas ce filtre.
"""

import base64
import hmac
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.environ.get("QWEN_VOICE_STATE", "/home/ludorl82/.local/state/qwen-voice")
TOKEN = os.environ.get("QWEN_VOICE_TOKEN", "")
LISTEN = os.environ.get("QWEN_VOICE_LISTEN", "127.0.0.1")
PORT = int(os.environ.get("QWEN_VOICE_PORT", "8791"))
TIMEOUT = float(os.environ.get("QWEN_VOICE_TIMEOUT", "45"))
LATE_WINDOW = float(os.environ.get("QWEN_LATE_WINDOW", "900"))
# OpenCode, dans le conteneur. L'adresse est résolue au besoin (IP du pont
# docker) ; en test, une URL fixe.
OC_URL = os.environ.get("QWEN_OPENCODE_URL", "")
OC_PORT = int(os.environ.get("QWEN_OPENCODE_PORT", "4096"))
DOCKER = os.environ.get("QWEN_DOCKER", "docker")
TMUX = shlex.split(os.environ.get("QWEN_TMUX", "docker exec -u ludorl82 console tmux -L console"))
SERVE = os.environ.get("QWEN_SERVE", "/home/ludorl82/.local/share/qwen-voice/opencode-serve.sh")
ATTACH = os.environ.get("QWEN_ATTACH", "/home/ludorl82/.local/share/qwen-voice/opencode-attach.sh")
NAMEGEN = os.environ.get("QWEN_NAMEGEN", "")
WORKDIR = os.environ.get("QWEN_WORKDIR", "/home/ludorl82/observateur")
AGENT = os.environ.get("QWEN_AGENT", "observateur")
# Modèle de repli quand un fournisseur refuse un tour pour son contenu
# (le filtre d'Alibaba, du temps de qwen3.8-flash) : « fournisseur/modèle »
# pour OpenCode. Vide = pas de repli ; le modèle par défaut (Muse, chez
# Meta) n'a pas ce filtre.
FALLBACK = os.environ.get("QWEN_FALLBACK_MODEL", "")
TMUX_SESSION = "observateur"
SERVER_WINDOW = "gaming-01"
MODEL = "qwen-tmux"
HISTORY_KEEP = 20
LATE_KEEP = 5

MANIFEST = os.path.join(STATE, "sessions.json")
HISTORY = os.path.join(STATE, "history.jsonl")
PASSWORD_FILE = os.path.join(STATE, "opencode-password")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
FILTERED = "DataInspectionFailed"

PREFIX = ("[vocal] Réponds en français, en une ou deux phrases courtes, sans "
          "markdown ni liste : ta réponse sera lue à voix haute. Si la question "
          "porte sur l'état ACTUEL du labo, vérifie avec une commande avant de "
          "répondre, jamais de mémoire : les alertes avec `labo-alertes`, la santé "
          "du cluster avec `labo-sante`. ")

LOCK = threading.RLock()
VOICE_LOCK = threading.Lock()
PENDING = {}            # id -> demande en attente (miroir des événements)
DECIDED_BY_APP = set()
LATE = []
WAITERS = {}            # sessionID -> [threading.Event, [événements]]


def log(msg):
    print(f"qwen-hub: {msg}", file=sys.stderr, flush=True)


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


# --- manifeste --------------------------------------------------------------

def load():
    try:
        with open(MANIFEST) as f:
            m = json.load(f)
    except (OSError, ValueError):
        m = {}
    m.setdefault("sessions", {})
    m.setdefault("active", None)
    return m


def save(m):
    tmp = MANIFEST + ".new"
    with open(tmp, "w") as f:
        json.dump(m, f, indent=1)
    os.replace(tmp, MANIFEST)


def name_of(sid):
    for n, s in load()["sessions"].items():
        if s == sid:
            return n
    return None


# --- OpenCode ---------------------------------------------------------------

def password():
    """Mot de passe du gaming-01 OpenCode : créé ici au premier démarrage, lu
    par le lanceur dans le conteneur (même fichier, même chemin), illisible
    pour l'agent (refus de lecture sur ce dossier)."""
    if not os.path.exists(PASSWORD_FILE):
        old = os.umask(0o077)
        try:
            with open(PASSWORD_FILE, "w") as f:
                f.write(base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip("="))
        finally:
            os.umask(old)
    with open(PASSWORD_FILE) as f:
        return f.read().strip()


def base():
    if OC_URL:
        return OC_URL
    ip = subprocess.run([DOCKER, "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                         "console"], capture_output=True, text=True, timeout=10).stdout.strip()
    return f"http://{ip}:{OC_PORT}"


def oc(method, path, body=None, timeout=30):
    auth = base64.b64encode(f"opencode:{password()}".encode()).decode()
    r = urllib.request.Request(base() + path, method=method,
                               data=json.dumps(body).encode() if body is not None else None,
                               headers={"Content-Type": "application/json", "Authorization": "Basic " + auth})
    with urllib.request.urlopen(r, timeout=timeout) as f:
        t = f.read()
        return json.loads(t) if t else None


def oc_up():
    try:
        oc("GET", "/session", timeout=5)
        return True
    except Exception:
        return False


def last_assistant(sid):
    msgs = oc("GET", f"/session/{sid}/message?limit=6") or []
    for m in reversed(msgs):
        info = m.get("info") or {}
        if info.get("role") == "assistant":
            text = " ".join(p.get("text", "") for p in m.get("parts") or [] if p.get("type") == "text").strip()
            err = json.dumps(info.get("error") or "", ensure_ascii=False)
            return text, err
    return "", ""


def events():
    """Suit le flux d'événements d'OpenCode : demandes d'autorisation,
    réponses, fins de tour. Se reconnecte à chaque coupure."""
    while True:
        try:
            auth = base64.b64encode(f"opencode:{password()}".encode()).decode()
            r = urllib.request.Request(base() + "/event", headers={"Authorization": "Basic " + auth})
            with urllib.request.urlopen(r, timeout=3600) as f:
                for raw in f:
                    line = raw.decode("utf-8", "replace").strip()
                    if line.startswith("data:"):
                        try:
                            handle(json.loads(line[5:]))
                        except ValueError:
                            pass
        except Exception as e:  # gaming-01 arrêté, redémarrage…
            log(f"flux d'événements coupé ({e.__class__.__name__}) ; reprise")
            time.sleep(3)


def handle(e):
    t, p = e.get("type", ""), e.get("properties") or {}
    sid = p.get("sessionID")
    if t == "permission.asked":
        with LOCK:
            PENDING[p["id"]] = {"id": p["id"], "session": name_of(sid) or sid, "sid": sid, "_seen": time.monotonic(),
                                "tool": p.get("permission"),
                                "summary": ((p.get("metadata") or {}).get("command")
                                            or " ".join(p.get("patterns") or []))[:300],
                                "since": now()}
        log(f"demande {p['id'][-8:]} dans {name_of(sid) or sid}")
    elif t == "permission.replied":
        rid = p.get("requestID")
        with LOCK:
            q = PENDING.pop(rid, None)
            if q:
                src = "appli" if rid in DECIDED_BY_APP else "terminal"
                DECIDED_BY_APP.discard(rid)
                entry = {k: v for k, v in q.items() if k not in ("sid", "_seen")}
                entry.update(allowed=p.get("reply") in ("once", "always"), source=src, decided=now())
                with open(HISTORY, "a") as f:
                    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    with LOCK:
        w = WAITERS.get(sid)
    if w and t in ("session.idle", "permission.asked", "session.error"):
        w[1].append(t)
        w[0].set()


def history():
    try:
        with open(HISTORY) as f:
            lines = f.readlines()[-HISTORY_KEEP:]
    except OSError:
        return []
    return [json.loads(x) for x in reversed(lines) if x.strip()]


# --- tmux -------------------------------------------------------------------

def tmux(*args, check=True):
    r = subprocess.run(TMUX + list(args), capture_output=True, text=True, timeout=30)
    if check and r.returncode != 0:
        raise RuntimeError(f"tmux {args[0]}: {r.stderr.strip() or r.returncode}")
    return r


def windows():
    r = tmux("list-windows", "-t", TMUX_SESSION, "-F", "#{window_name}", check=False)
    return r.stdout.split() if r.returncode == 0 else []


def open_window(name, cmd):
    if tmux("has-session", "-t", TMUX_SESSION, check=False).returncode == 0:
        tmux("new-window", "-d", "-t", f"{TMUX_SESSION}:", "-n", name, "-c", WORKDIR, cmd)
    else:
        tmux("new-session", "-d", "-s", TMUX_SESSION, "-n", name, "-c", WORKDIR, cmd)


def attach_cmd(sid):
    return f"bash --norc --noprofile {shlex.quote(ATTACH)} {shlex.quote(sid)}"


# --- sessions ---------------------------------------------------------------

def new_name(taken):
    if NAMEGEN:
        r = subprocess.run(["bash", NAMEGEN, *taken], capture_output=True, text=True, timeout=10)
        n = r.stdout.strip()
        if r.returncode == 0 and NAME_RE.match(n) and n not in taken:
            return n
    i = 1
    while f"qwen-{i}" in taken:
        i += 1
    return f"qwen-{i}"


def add_session(name=None):
    with LOCK:
        m = load()
        taken = set(m["sessions"]) | set(windows())
        name = name or new_name(sorted(taken))
        if not NAME_RE.match(name) or name in taken or name == SERVER_WINDOW:
            raise ValueError(f"nom refusé : {name}")
        sid = oc("POST", "/session", {"title": name})["id"]
        m["sessions"][name] = sid
        m["active"] = m["active"] or name
        save(m)
    open_window(name, attach_cmd(sid))
    return name


def remove_session(name):
    with LOCK:
        m = load()
        sid = m["sessions"].get(name)
        if not sid:
            raise ValueError(f"session inconnue : {name}")
        tmux("kill-window", "-t", f"{TMUX_SESSION}:={name}", check=False)
        try:
            oc("DELETE", f"/session/{sid}")
        except urllib.error.HTTPError:
            pass
        del m["sessions"][name]
        if m["active"] == name:
            m["active"] = next(iter(m["sessions"]), None)
        save(m)
        for rid in [r for r, p in PENDING.items() if p["sid"] == sid]:
            del PENDING[rid]


def rename_session(old, new):
    with LOCK:
        m = load()
        if old not in m["sessions"]:
            raise ValueError(f"session inconnue : {old}")
        if not NAME_RE.match(new or "") or new in m["sessions"] or new in windows() or new == SERVER_WINDOW:
            raise ValueError(f"nom refusé : {new}")
        oc("PATCH", f"/session/{m['sessions'][old]}", {"title": new})
        tmux("rename-window", "-t", f"{TMUX_SESSION}:={old}", new, check=False)
        m["sessions"][new] = m["sessions"].pop(old)
        if m["active"] == old:
            m["active"] = new
        save(m)
        for p in PENDING.values():
            if p["session"] == old:
                p["session"] = new


def clear_session(name):
    """Nouvelle conversation sous le même nom ; l'ancienne est supprimée."""
    with LOCK:
        m = load()
        old = m["sessions"].get(name)
        if not old:
            raise ValueError(f"session inconnue : {name}")
        sid = oc("POST", "/session", {"title": name})["id"]
        m["sessions"][name] = sid
        save(m)
        tmux("respawn-window", "-k", "-t", f"{TMUX_SESSION}:={name}", attach_cmd(sid), check=False)
        try:
            oc("DELETE", f"/session/{old}")
        except urllib.error.HTTPError:
            pass


def activate(name):
    with LOCK:
        m = load()
        if name not in m["sessions"]:
            raise ValueError(f"session inconnue : {name}")
        m["active"] = name
        save(m)


def restore():
    """Au démarrage : le gaming-01 OpenCode, puis une fenêtre par session."""
    for _ in range(60):
        if subprocess.run(TMUX + ["-V"], capture_output=True).returncode == 0:
            break
        time.sleep(2)
    password()
    if SERVER_WINDOW not in windows():
        log("démarrage du gaming-01 OpenCode")
        open_window(SERVER_WINDOW, f"bash --norc --noprofile {shlex.quote(SERVE)}")
    for _ in range(90):
        if oc_up():
            break
        time.sleep(2)
    else:
        log("le gaming-01 OpenCode ne répond pas ; les sessions attendront")
        return
    known = {s["id"]: s.get("directory") for s in oc("GET", "/session") or []}
    moved = set()
    with LOCK:
        m = load()
        for name, sid in list(m["sessions"].items()):
            if sid not in known:
                log(f"{name} : conversation {sid} introuvable, nouvelle conversation")
            elif known[sid] != WORKDIR:
                # OpenCode publishes a session's events on the bus of ITS
                # directory, and /event only follows the server's: a
                # conversation left in an older workdir (~/qwen before the
                # observer rename) never reports its end, and every voice
                # turn waits out the full delay. The old one is kept.
                log(f"{name} : conversation dans {known[sid]}, pas {WORKDIR} ; nouvelle conversation")
                moved.add(name)
            else:
                continue
            m["sessions"][name] = oc("POST", "/session", {"title": name})["id"]
        save(m)
        present = set(windows())
        for name, sid in m["sessions"].items():
            if name not in present:
                open_window(name, attach_cmd(sid))
            elif name in moved:
                tmux("respawn-window", "-k", "-t", f"{TMUX_SESSION}:={name}", attach_cmd(sid), check=False)
    if not load()["sessions"]:
        log("aucune session : création de « bureau »")
        add_session("bureau")


# --- approbations et état ---------------------------------------------------

def approve(rid, allowed):
    with LOCK:
        if rid not in PENDING:
            live = {p["id"] for p in oc("GET", "/permission") or []}
            if rid not in live:
                raise ValueError("demande inconnue ou déjà tranchée")
        DECIDED_BY_APP.add(rid)
    oc("POST", f"/permission/{rid}/reply", {"reply": "once" if allowed else "reject"})


def state():
    m = load()
    present = set(windows())
    try:
        live = oc("GET", "/permission", timeout=5) or []
    except Exception:
        live = None      # OpenCode injoignable : on garde le miroir tel quel
    with LOCK:
        if live is not None:
            for p in live:   # une demande arrivée pendant une coupure du flux
                if p["id"] not in PENDING:
                    handle({"type": "permission.asked", "properties": p})
            # Drop what OpenCode no longer lists — but not in the seconds
            # between the reply and its « permission.replied » event, or the
            # decision would never reach the history (seen in the tests).
            live_ids = {p["id"] for p in live}
            for rid in [r for r, q in PENDING.items()
                        if r not in live_ids and time.monotonic() - q.get("_seen", 0) > 30]:
                PENDING.pop(rid, None)
        pending = sorted(({k: v for k, v in p.items() if k not in ("sid", "_seen")} for p in PENDING.values()),
                         key=lambda p: p["since"])
        late = list(LATE)
    return {"active": m["active"],
            "sessions": [{"name": n, "running": n in present,
                          "pending": sum(1 for p in pending if p["session"] == n)}
                         for n in m["sessions"]],
            "names": list(m["sessions"]),
            "pending": pending, "history": history(), "late": late}


# --- voix -------------------------------------------------------------------

def last_user_text(body):
    for msg in reversed(body.get("messages") or []):
        if msg.get("role") == "user":
            c = msg.get("content")
            if isinstance(c, list):
                c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return (c or "").strip()
    return ""


def send(sid, text, model=None):
    body = {"agent": AGENT, "parts": [{"type": "text", "text": text}]}
    if model:
        prov, _, mid = model.partition("/")
        body["model"] = {"providerID": prov, "modelID": mid}
    oc("POST", f"/session/{sid}/prompt_async", body)


def arm(sid):
    """S'abonne aux fins de tour d'une session AVANT d'envoyer : un tour
    court pourrait finir avant qu'on commence à écouter."""
    w = [threading.Event(), []]
    with LOCK:
        WAITERS[sid] = w
    return w


def wait_turn(sid, w, deadline, until=("idle", "permission")):
    """Attend « idle » ou « permission » (selon `until`) ; None au délai."""
    try:
        while time.monotonic() < deadline:
            w[0].wait(max(0.0, min(1.0, deadline - time.monotonic())))
            w[0].clear()
            with LOCK:
                got, w[1][:] = list(w[1]), []
            if "permission" in until and "permission.asked" in got:
                return "permission"
            if "session.idle" in got or "session.error" in got:
                return "idle"
        return None
    finally:
        with LOCK:
            if WAITERS.get(sid) is w:
                WAITERS.pop(sid, None)


def late_answer(name, sid, question):
    """Garde la réponse FINALE d'un tour que la voix a quitté (délai dépassé
    ou autorisation demandée) : on attend la vraie fin du tour, en ignorant
    les demandes d'autorisation intermédiaires."""
    w = arm(sid)
    if wait_turn(sid, w, time.monotonic() + LATE_WINDOW, until=("idle",)) is None:
        return
    text, err = last_assistant(sid)
    if FILTERED in err and not text:
        text = "Le filtre d'Alibaba a bloqué ce tour ; repose la question."
    if not text:
        return
    with LOCK:
        LATE.append({"id": base64.b16encode(os.urandom(8)).decode().lower(), "session": name,
                     "question": question, "text": text, "at": now()})
        del LATE[:-LATE_KEEP]
    log(f"réponse tardive de {name} gardée pour annonce")


def ask(question):
    m = load()
    name = m["active"]
    sid = m["sessions"].get(name) if name else None
    if not sid:
        return "Aucune session n'est active."
    text = PREFIX + question
    with VOICE_LOCK:
        deadline = time.monotonic() + TIMEOUT
        note = ""
        w = arm(sid)
        send(sid, text)
        end = wait_turn(sid, w, deadline)
        if end == "idle":
            answer, err = last_assistant(sid)
            if FILTERED in err and FALLBACK:
                log(f"{name} : bloqué par le filtre de contenu, repli sur {FALLBACK}")
                note = "Le filtre d'Alibaba a bloqué la question ; je passe par l'autre modèle. "
                w = arm(sid)
                send(sid, text, FALLBACK)
                end = wait_turn(sid, w, deadline)
                if end == "idle":
                    answer, err = last_assistant(sid)
            if end == "idle":
                if not answer and err != '""':
                    # e.g. OpenRouter's 404 when the account's privacy settings
                    # exclude the model's only endpoint: say so, not « no answer ».
                    log(f"{name} : erreur du fournisseur : {err[:300]}")
                    return note + "Le fournisseur du modèle a refusé la requête ; le détail est dans le terminal."
                return note + (answer or "Je n'ai pas de réponse, regarde le terminal.")
        threading.Thread(target=late_answer, args=(name, sid, question), daemon=True).start()
        if end == "permission":
            return note + "J'attends ton OK, dans l'application ou dans le terminal."
        return note + "C'est plus long que prévu ; je te l'annonce ici dès que c'est prêt."


# --- HTTP -------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "qwen-hub"

    def authorized(self):
        h = self.headers.get("Authorization", "")
        return bool(TOKEN) and h.startswith("Bearer ") and hmac.compare_digest(h[7:].strip(), TOKEN)

    def log_message(self, fmt, *args):
        path = self.path.split("?")[0] if self.authorized() else "(refusé)"
        if path == "/qwen/state" and len(args) > 1 and str(args[1]) == "200":
            return
        log(f"{self.address_string()} {self.command} {path} {args[1] if len(args) > 1 else ''}")

    def send_json(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.authorized():
            return self.send_json(404, {"error": "not found"})
        if self.path == "/api/tags":
            return self.send_json(200, {"models": [{
                "name": f"{MODEL}:latest", "model": f"{MODEL}:latest", "modified_at": now(),
                "size": 0, "digest": "0" * 64,
                "details": {"format": "bridge", "family": "qwen", "parameter_size": "", "quantization_level": ""}}]})
        if self.path == "/api/version":
            return self.send_json(200, {"version": "0.0.0-qwen-hub"})
        if self.path == "/qwen/state":
            return self.send_json(200, state())
        return self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self.authorized():
            return self.send_json(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self.send_json(400, {"error": "bad json"})
        try:
            if self.path == "/qwen/session":
                a = body.get("action")
                if a == "add":
                    return self.send_json(200, {"ok": True, "name": add_session()})
                fn = {"remove": lambda: remove_session(body.get("name")),
                      "rename": lambda: rename_session(body.get("name"), body.get("new")),
                      "activate": lambda: activate(body.get("name")),
                      "clear": lambda: clear_session(body.get("name"))}.get(a)
                if not fn:
                    return self.send_json(400, {"error": "action inconnue"})
                fn()
                return self.send_json(200, {"ok": True})
            if self.path == "/qwen/approve":
                approve(body.get("request_id"), body.get("allowed"))
                return self.send_json(200, {"ok": True})
        except (ValueError, RuntimeError, urllib.error.URLError) as err:
            return self.send_json(409, {"error": str(err)})
        if self.path == "/api/show":
            return self.send_json(200, {"modelfile": "", "parameters": "", "template": "",
                                        "details": {"family": "qwen"}, "capabilities": ["completion"]})
        if self.path != "/api/chat":
            return self.send_json(404, {"error": "not found"})
        question = last_user_text(body)
        t0 = time.monotonic()
        try:
            answer = ask(question) if question else "Je n'ai rien entendu."
        except (urllib.error.URLError, OSError) as err:
            log(f"voix : OpenCode injoignable ({err})")
            answer = "Le gaming-01 de l'observateur ne répond pas en ce moment."
        log(f"tour vocal en {time.monotonic() - t0:.1f} s")
        msg = {"model": body.get("model", MODEL), "created_at": now(),
               "message": {"role": "assistant", "content": answer}}
        final = {"model": body.get("model", MODEL), "created_at": now(),
                 "message": {"role": "assistant", "content": ""}, "done": True, "done_reason": "stop"}
        if body.get("stream", True):
            data = (json.dumps({**msg, "done": False}, ensure_ascii=False) + "\n"
                    + json.dumps(final, ensure_ascii=False) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_json(200, {**msg, "done": True, "done_reason": "stop"})


def main():
    if not TOKEN:
        log("QWEN_VOICE_TOKEN absent : refus de démarrer sans jeton")
        sys.exit(1)
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    threading.Thread(target=restore, daemon=True).start()
    threading.Thread(target=events, daemon=True).start()
    log(f"écoute sur {LISTEN}:{PORT}, état dans {STATE}")
    ThreadingHTTPServer((LISTEN, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
