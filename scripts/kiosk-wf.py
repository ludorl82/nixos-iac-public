"""kiosk-wf — the rack kiosk's few words of Wayfire IPC.

modules/kiosk.nix runs the kiosk on Wayfire for its cube (sway stays as the
fallback). Wayfire ships no command-line client and nixpkgs no Python one, so
this speaks the socket directly: a 4-byte little-endian length, then JSON
{"method": ..., "data": {...}}, both ways (Wayfire 0.10 ipc plugin).

  kiosk-wf current                  index of the workspace shown (0-based, x)
  kiosk-wf rotate left|right [n]    the cube, n faces (one IPC call per face)
  kiosk-wf show X                   jump to workspace X, no animation
  kiosk-wf place PREFIX X           wait for the window whose app-id starts
                                    with PREFIX, send it to workspace X,
                                    full screen

Method names and arguments read off Wayfire 0.10.1 and pywayfire
(2026-10-09): window-rules/get-focused-output, window-rules/list-views,
vswitch/set-workspace, vswitch/send-view, wm-actions/set-fullscreen,
cube/rotate_left, cube/rotate_right.
"""
import glob
import json
import os
import socket
import struct
import sys
import time


def socket_path():
    path = os.environ.get("WAYFIRE_SOCKET")
    if path:
        return path
    # Called from outside the session (ssh, a test by hand): find it.
    run = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    found = sorted(glob.glob(os.path.join(run, "wayfire-*.socket")), key=os.path.getmtime)
    if not found:
        raise SystemExit("kiosk-wf: no Wayfire socket")
    return found[-1]


class Wayfire:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(socket_path())

    def _read(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise SystemExit("kiosk-wf: Wayfire closed the socket")
            buf += chunk
        return buf

    def call(self, method, **data):
        body = json.dumps({"method": method, "data": data}).encode()
        self.s.sendall(struct.pack("<I", len(body)) + body)
        (n,) = struct.unpack("<I", self._read(4))
        reply = json.loads(self._read(n))
        if isinstance(reply, dict) and reply.get("result") == "error":
            raise SystemExit(f"kiosk-wf: {method}: {reply.get('error')}")
        return reply

    def output(self):
        reply = self.call("window-rules/get-focused-output")
        return reply.get("info", reply)


def current(wf):
    return wf.output()["workspace"]["x"]


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    wf = Wayfire()
    if cmd == "current" and len(argv) == 2:
        print(current(wf))
    elif cmd == "rotate" and len(argv) in (3, 4) and argv[2] in ("left", "right"):
        n = int(argv[3]) if len(argv) == 4 else 1
        # Each call during a rotation adds one more face to it.
        for _ in range(max(0, n)):
            wf.call(f"cube/rotate_{argv[2]}")
    elif cmd == "show" and len(argv) == 3:
        out = wf.output()
        wf.call("vswitch/set-workspace", x=int(argv[2]), y=0, **{"output-id": out["id"]})
    elif cmd == "place" and len(argv) == 4:
        prefix, x = argv[2], int(argv[3])
        deadline = time.time() + 60
        while time.time() < deadline:
            views = wf.call("window-rules/list-views")
            if isinstance(views, dict):
                views = views.get("info", [])
            mine = [v for v in views
                    if str(v.get("app-id", "")).startswith(prefix) and v.get("mapped", True)]
            if mine:
                vid = mine[0]["id"]
                out = wf.output()
                # Full screen FIRST: it brings the view back to the workspace
                # shown (stella, 2026-10-09: both desktops ended up on face 0).
                wf.call("wm-actions/set-fullscreen", view_id=vid, state=True)
                time.sleep(0.5)
                # Geometry is relative to the workspace shown, not to face 0
                # (a window reopened while on another face, 2026-10-09).
                want = (x - out["workspace"]["x"]) * out["geometry"]["width"]
                for _ in range(10):
                    wf.call("vswitch/send-view", x=x, y=0,
                            **{"view-id": vid, "output-id": out["id"]})
                    time.sleep(0.5)
                    views = wf.call("window-rules/list-views")
                    if isinstance(views, dict):
                        views = views.get("info", [])
                    geo = next((v.get("geometry", {}) for v in views if v.get("id") == vid), {})
                    if geo.get("x") == want:
                        return
                raise SystemExit(f"kiosk-wf: {prefix}* did not land on face {x}")
            time.sleep(0.5)
        raise SystemExit(f"kiosk-wf: no window with app-id {prefix}* after 60 s")
    else:
        raise SystemExit(__doc__.split("\n\n")[2])


if __name__ == "__main__":
    main(sys.argv)
