"""kiosk-bmc — drive one kiosk Chromium window over the DevTools protocol.

modules/kiosk.nix gives every desktop of the rack kiosk its own Chromium,
listening for DevTools on 127.0.0.1:<port>. This is the only thing that talks
to it:

  kiosk-bmc login  <port> <bmc-base-url> <password-file>
  kiosk-bmc watch  <port> <bmc-base-url> <password-file>
  kiosk-bmc logout <port> <bmc-base-url> <placeholder-url>
  kiosk-bmc open   <port> <url>
  kiosk-bmc reload <port>
  kiosk-bmc state  <port>                      ok | login | dropped

WHY LOG IN THROUGH THE PAGE (2026-10-09). The X11SRA BMCs (firmware 1.74)
hide the HTML5 iKVM from their menu — only the Java console is offered — but
/cgi/url_redirect.cgi?url_name=man_ikvm_html5_bootstrap serves it to any
logged-in session (checked on bob and stella). Their login form base64-encodes
name and password in its own JavaScript (checkform() on the login page) before
POSTing to /cgi/login.cgi with check=00; older firmware sent them in clear.
Filling the real form and calling the page's own checkform() survives either
encoding. The session cookie is HttpOnly + Secure, so it could not be made
elsewhere and handed to Chromium anyway.

The password is read from a root:kiosk 0640 file and goes to the page through
the DevTools socket on localhost: never argv, never written anywhere.

THE WATCHER (2026-10-09, first day on the rack screen). A BMC page left alone
does two things that freeze a kiosk nobody is typing on: its web session
times out and it opens a blocking alert ("Your session has timed out"), and
the HTML5 viewer drops with "Server disconnected (code 1006)". `watch` stays
attached to the desktop's page, accepts every dialog, and reconnects: first
after RETRY_FIRST seconds, then doubling up to RETRY, so a BMC that keeps
refusing is not hammered. (A flat 300 s left the rack screen on the login page
for five minutes after a timeout, stella, 2026-10-09.)

KEEP THE CONSOLE WHEN THE WEB SESSION EXPIRES (2026-10-10). Supermicro's
pages answer an expired web session with SessionTimeout() (js/utils.js): an
alert, then location.href = "../cgi/logout.cgi". That logout is what closed
the iKVM ("disconnection due to user logout", 1006); the viewer's own stream
outlives the web session. The watcher holds the page and answers any
navigation to logout.cgi with "204 No Content", which leaves the page where it
is. Only the watcher does it, so `logout` (screen asleep) still logs out: the
watcher is stopped first (kiosk-desktop.sh, stop_watch). Every interception
and dialog goes to the journal (kiosk-bmc).

ONE ATTEMPT, NO LOOP. The BMCs keep a tiny pool of web sessions and scripted
logins evict a human's own session (seen 2026-07-25). A failed login exits
non-zero and leaves the placeholder; the human presses KP0 to try again.
"""
import base64
import json
import sys
import syslog
import time
import urllib.request

import websocket

USER = "ADMIN"
IKVM = "/cgi/url_redirect.cgi?url_name=man_ikvm_html5_bootstrap"
LOGOUT = "/cgi/logout.cgi"
# The iKVM page is a noVNC canvas inside Supermicro's white Bootstrap page.
# Ludo wants the console alone, full screen (2026-10-09): hide the menu bar,
# black page, the canvas stretched to the window with its proportions kept.
# Injected by the watcher into every page it loads, applied to the viewer only.
FULLSCREEN_JS = """(function () {
  if (location.search.indexOf('man_ikvm_html5') < 0) return;
  function add() {
    if (document.getElementById('kiosk-full')) return;
    var s = document.createElement('style');
    s.id = 'kiosk-full';
    s.textContent = 'html,body{background:#000!important;overflow:hidden!important}'
      + '.navbar{display:none!important}'
      + '#noVNC_canvas{position:fixed!important;left:0!important;top:0!important;'
      + 'width:100vw!important;height:100vh!important;object-fit:contain;'
      + 'z-index:9998;background:#000}'
      + '#dialog,.ui-dialog{z-index:9999!important}';
    (document.head || document.documentElement).appendChild(s);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', add);
  else add();
})()"""
RETRY_FIRST = 20   # seconds before the watcher's first reconnection
RETRY = 300        # at most this long between two, after failures
CHECK = 20    # seconds between two looks at the page
# What the page looks like when it needs a reconnection.
STATE_JS = """(function () {
  if (document.form1 && typeof checkform === 'function') return 'login';
  var t = (document.body && document.body.innerText) || '';
  if (/code:\\s*1006|Server disconnected|disconnection due to user logout/i.test(t)) return 'dropped';
  // The viewer titles itself "Resolution:WxH FPS :n" once frames arrive; on
  // bob (2026-10-09) it sat on "Console Redirection" with no picture.
  if (location.search.indexOf('man_ikvm_html5') >= 0 && performance.now() > 30000
      && document.title.indexOf('Resolution') !== 0) return 'dropped';
  return 'ok';
})()"""


class Page:
    def __init__(self, port):
        deadline = time.time() + 30
        while True:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2) as r:
                    targets = json.load(r)
                pages = [t for t in targets if t.get("type") == "page"]
                # The kiosk window is the oldest page; /json lists the newest
                # first. Any other one is a popup (bob's BMC opened the iKVM in
                # a 640x640 window over the kiosk, 2026-10-09): close it.
                page = pages[-1]
                for extra in pages[:-1]:
                    urllib.request.urlopen(f"http://127.0.0.1:{port}/json/close/{extra['id']}",
                                           timeout=2).read()
                break
            except Exception:
                if time.time() > deadline:
                    raise SystemExit(f"kiosk-bmc: no Chromium page on port {port}")
                time.sleep(0.5)
        # No Origin header: Chromium rejects a DevTools websocket that carries
        # one it does not list in --remote-allow-origins (stella, 2026-10-09).
        self.ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=30,
                                              suppress_origin=True)
        self.n = 0
        self.port = port
        self.call("Page.enable")

    def send(self, method, **params):  # fire and forget, from an event handler
        self.ws.send(json.dumps({"id": 0, "method": method, "params": params}))

    def event(self, msg):
        """Answer what must not wait: dialogs, and requests held by Fetch."""
        if msg.get("method") == "Page.javascriptDialogOpening":
            # A BMC "session timeout" alert would freeze the kiosk; dismiss it.
            log(f"{self.port}: dialog: {msg['params'].get('message', '')}")
            self.send("Page.handleJavaScriptDialog", accept=True)
        elif msg.get("method") == "Fetch.requestPaused":
            req = msg["params"]
            if LOGOUT in req["request"]["url"]:
                log(f"{self.port}: kept the console, refused {req['request']['url']}")
                self.send("Fetch.fulfillRequest", requestId=req["requestId"], responseCode=204,
                          responseHeaders=[], body=base64.b64encode(b"").decode())
            else:
                self.send("Fetch.continueRequest", requestId=req["requestId"])

    def call(self, method, **params):
        self.n += 1
        self.ws.send(json.dumps({"id": self.n, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            self.event(msg)
            if msg.get("id") == self.n:
                if "error" in msg:
                    raise SystemExit(f"kiosk-bmc: {method}: {msg['error'].get('message')}")
                return msg.get("result", {})

    def js(self, expr):
        r = self.call("Runtime.evaluate", expression=expr, returnByValue=True)
        return r.get("result", {}).get("value")

    def wait(self, expr, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                if self.js(expr):
                    return True
            except SystemExit:
                pass  # navigation in progress: the context is being replaced
            time.sleep(0.5)
        return False

    def goto(self, url):
        self.call("Page.navigate", url=url)


def log(text):
    syslog.syslog(text)


def read_pw(pwfile):
    try:
        with open(pwfile) as f:
            return f.read().strip()
    except OSError as e:
        raise SystemExit(f"kiosk-bmc: cannot read {pwfile}: {e.strerror}")


def login(port, base, pwfile):
    do_login(Page(port), base, read_pw(pwfile))


def do_login(p, base, pw):
    p.goto(base + "/")
    if not p.wait("typeof checkform === 'function' && !!document.form1", 20):
        raise SystemExit(f"kiosk-bmc: no login form at {base}")
    # The page's pwd field is type="text" and only masks itself on a real
    # keystroke (oninput -> turnOnPwdStyle). Setting .value by script fires
    # no input event, so the password showed IN CLEAR on the rack screen until
    # the POST (seen by Ludo, 2026-10-17): mask the field first, then fill it.
    p.js("document.form1.pwd.type = 'password'; document.form1.name.value = %s;"
         " document.form1.pwd.value = %s; checkform();"
         % (json.dumps(USER), json.dumps(pw)))
    # Success leaves the login page (to the main menu); failure reloads it.
    if not p.wait("!location.pathname.startsWith('/cgi/login') && !document.form1", 20):
        raise SystemExit(f"kiosk-bmc: login to {base} did not complete")
    p.goto(base + IKVM)


def reconnect(p, base, pwfile):
    """The viewer first: a dropped viewer often has a live session behind it."""
    p.goto(base + IKVM)
    # An expired session lands on the login page, sometimes only after a few
    # seconds; a live one titles itself "Resolution:..." once frames arrive.
    p.wait("(document.form1 && typeof checkform === 'function')"
           " || location.pathname.startsWith('/cgi/login')"
           " || /^Resolution/.test(document.title)", 20)
    if p.js(STATE_JS) == "login" or p.wait("location.pathname.startsWith('/cgi/login')", 1):
        do_login(p, base, read_pw(pwfile))


def watch(port, base, pwfile):
    p = Page(port)
    p.call("Page.addScriptToEvaluateOnNewDocument", source=FULLSCREEN_JS)
    p.js(FULLSCREEN_JS)
    # Hold navigations to logout.cgi: see KEEP THE CONSOLE above.
    p.call("Fetch.enable", patterns=[{"urlPattern": "*" + LOGOUT + "*"}])
    p.ws.settimeout(CHECK)
    last_try = 0.0
    last_look = 0.0
    wait = RETRY_FIRST
    while True:
        need = False
        try:
            # A "session timed out" alert no longer means a reconnection: the
            # logout behind it is refused, and the viewer usually lives on. The
            # look at the page below decides.
            p.event(json.loads(p.ws.recv()))
        except websocket.WebSocketTimeoutException:
            pass
        except websocket.WebSocketConnectionClosedException:
            return  # Chromium is gone; kiosk-desktop starts a new watcher with the next load
        now = time.time()
        if not need and now - last_look >= CHECK:
            last_look = now
            try:
                state = p.js(STATE_JS)
            except SystemExit:
                state = None  # page navigating; look again next round
            need = state in ("login", "dropped")
            if state == "ok":
                wait = RETRY_FIRST  # healthy again: the next fall retries quickly
        if need and now - last_try >= wait:
            last_try = now
            wait = min(wait * 2, RETRY)
            log(f"{port}: console fell, reconnecting")
            try:
                reconnect(p, base, pwfile)
            except SystemExit as e:
                log(f"{port}: {e}")


def logout(port, base, placeholder):
    p = Page(port)
    p.goto(base + LOGOUT)
    time.sleep(2)
    p.goto(placeholder)


def main(argv):
    syslog.openlog("kiosk-bmc")
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "login" and len(argv) == 5:
        login(argv[2], argv[3].rstrip("/"), argv[4])
    elif cmd == "watch" and len(argv) == 5:
        watch(argv[2], argv[3].rstrip("/"), argv[4])
    elif cmd == "logout" and len(argv) == 5:
        logout(argv[2], argv[3].rstrip("/"), argv[4])
    elif cmd == "open" and len(argv) == 4:
        Page(argv[2]).goto(argv[3])
    elif cmd == "state" and len(argv) == 3:
        print(Page(argv[2]).js(STATE_JS))
    elif cmd == "reload" and len(argv) == 3:
        Page(argv[2]).call("Page.reload", ignoreCache=True)
    else:
        raise SystemExit(__doc__.split("\n\n")[1])


if __name__ == "__main__":
    main(sys.argv)
