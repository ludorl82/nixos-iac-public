#!/usr/bin/env python3
"""Keep Bob's voice prompt in bob's prompt cache, the way a Voice PE builds it.

The voice agent's first question used to recompute its whole prompt (~5 200
tokens, 6-8 s on qwen38-27b) even with HA's 06:00 warm-up automation: that
automation calls conversation.process, which takes no device, so it warms the
DEVICE-LESS prompt (~4 500 tokens). A question from a Voice PE carries the
satellite's context in the middle of the prompt, shares only ~3 700 tokens with
it, and qwen38 (hybrid attention) can only resume from a checkpoint below the
divergence — so it starts over from token 0. Measured 2026-10-01: dining-room
Voice PE, first question 7.4 s, next one 0.8 s.

HA's websocket API does take a device_id, so the warm-up runs from here:
one harmless question per context, every hour (the prompt carries the date, and
bob loses its RAM prompt cache on every restart). A context already in cache
costs ~0.3 s of GPU.

Token: the non-admin HA user « Observateur » (KeePass « Home Assistant
Observateur Token »), not the admin one. TLS: automatron's Cloudflare Origin
certificate, verified against the pinned Origin roots by its real name while
dialling the IP (same seam as ha-backup.py).
"""
import asyncio
import json
import os
import ssl
import subprocess
import sys
import time

import websockets

IP = "192.0.2.34"
NAME = "automatron.family.example"
AGENT = "conversation.ollama_conversation"
TEXT = "quel jour on est"
# (label, device_id or None). Only devices whose pipeline uses Bob's agent:
# the office Voice PE talks to the observer (OpenCode), not to bob.
CONTEXTS = [
    ("sans appareil (appli)", None),
    ("Voice PE salle à manger", "f698fa8815fa6417200cd04934891233"),
]


async def warm(token):
    ctx = ssl.create_default_context(cafile=os.environ["CF_ORIGIN_ROOTS"])
    sock_kw = {"ssl": ctx, "server_hostname": NAME, "host": IP, "port": 443}
    async with websockets.connect(f"wss://{NAME}/api/websocket", open_timeout=20, **sock_kw) as ws:
        await ws.recv()
        await ws.send(json.dumps({"type": "auth", "access_token": token}))
        if json.loads(await ws.recv()).get("type") != "auth_ok":
            print("bob-voice-warm: jeton refusé", file=sys.stderr)
            return 1
        rc = 0
        for i, (label, device) in enumerate(CONTEXTS, 1):
            msg = {"id": i, "type": "conversation/process", "text": TEXT, "agent_id": AGENT, "language": "fr"}
            if device:
                msg["device_id"] = device
            t = time.monotonic()
            await ws.send(json.dumps(msg))
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), 120))
                if m.get("id") == i:
                    break
            ok = m.get("success") and (m.get("result") or {}).get("response", {}).get("response_type") != "error"
            print(f"bob-voice-warm: {label} : {'ok' if ok else 'ÉCHEC'} en {time.monotonic() - t:.1f} s")
            rc = rc or (0 if ok else 1)
        return rc


def main():
    r = subprocess.run([os.environ["KP_GET_BIN"], "Home Assistant Observateur Token"],
                       capture_output=True, text=True, timeout=60)
    token = r.stdout.strip()
    if r.returncode or not token:
        print("bob-voice-warm: jeton introuvable dans KeePass", file=sys.stderr)
        return 1
    return asyncio.run(warm(token))


if __name__ == "__main__":
    sys.exit(main())
