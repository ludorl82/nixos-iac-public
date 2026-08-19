#!/usr/bin/env python3
"""Ship ha-01's newest automatic Home Assistant backup to S3.

Pull model, mirroring scripts/homelab-backup.sh: Cronicle SSHes in on a
forced-command key, this runs, and Kuma hears about it either way.

Why it pulls instead of HA pushing: HA's own off-box agent (cloud.cloud)
had failed every night since 2026-02-23 without saying so, because the
local agent kept succeeding. A puller that reports to Kuma cannot fail
quietly the same way.

TLS: ha-01 serves a Cloudflare Origin cert whose SANs are
*.family.example / family.example -- it does NOT cover ha-01-local.lab.example.
So every connection here dials the box's IP while presenting (and
verifying against) the name the cert actually carries, pinned to
Cloudflare's Origin root. This is real verification, not verify=False.
The proper fix is a private-CA leaf for the real hostname; until then,
do not "simplify" any of this to -k.

No gpg wrapper, unlike homelab-backup.sh: HA backups are already AES
encrypted with the backup password when protected=true, and this refuses
to ship one that isn't. That makes the KeePass entry holding that
password the single thing standing between S3 and a restore.
"""
import asyncio, datetime, http.client, json, os, socket, ssl
import subprocess, sys, urllib.parse, urllib.request

HOST_NAME = "ha-01.family.example"        # the cert's SAN, not the DNS name
HOST_IP = "192.0.2.34"
BUCKET = "homelab-backups-example-com"
PREFIX = "ha-01"
KUMA_PUSH_URL = os.environ.get("KUMA_PUSH_URL", "")
CAFILE = os.environ.get("CF_ORIGIN_ROOTS", "/etc/ssl/certs/cloudflare-origin-roots.crt")
AWS = os.environ.get("AWS_BIN", "cloud-01")
KP_GET = os.environ.get("KP_GET_BIN", "/usr/local/bin/kp-get")
MAX_AGE_HOURS = 36        # a daily backup older than this means HA stopped


def kuma(status, msg):
    if not KUMA_PUSH_URL:
        return
    try:
        url = (f"{KUMA_PUSH_URL}?status={status}"
               f"&msg={urllib.parse.quote(msg[:120])}&ping=")
        urllib.request.urlopen(url, timeout=10).read()
    except Exception:
        pass


def die(msg):
    print(f"{datetime.datetime.now().isoformat()} ha-backup FAILED: {msg}",
          file=sys.stderr)
    kuma("down", msg)
    sys.exit(1)


def tls_context():
    return ssl.create_default_context(cafile=CAFILE)


def ha_token():
    r = subprocess.run([KP_GET, "Home Assistant Token"],
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        die("could not fetch HA token from KeePass")
    return r.stdout.strip()


def connect():
    """HTTPS connection to the IP, verified against the cert's SAN.

    http.client derives SNI from .host, so the socket is wrapped by hand:
    dial HOST_IP, verify HOST_NAME. Setting .sock makes request() skip its
    own connect().
    """
    raw = socket.create_connection((HOST_IP, 443), timeout=60)
    tls = tls_context().wrap_socket(raw, server_hostname=HOST_NAME)
    conn = http.client.HTTPSConnection(HOST_NAME, 443, timeout=120)
    conn.sock = tls
    return conn


async def newest_automatic_backup(token):
    """Ask HA's websocket API for the newest backup made by the schedule."""
    import websockets

    async with websockets.connect(
        f"wss://{HOST_NAME}/api/websocket", ssl=tls_context(),
        host=HOST_IP, port=443, max_size=None, open_timeout=20,
    ) as ws:
        await ws.recv()
        await ws.send(json.dumps({"type": "auth", "access_token": token}))
        if json.loads(await ws.recv()).get("type") != "auth_ok":
            die("HA websocket auth rejected")

        await ws.send(json.dumps({"id": 1, "type": "backup/info"}))
        while True:
            m = json.loads(await ws.recv())
            if m.get("id") == 1 and m.get("type") == "result":
                break
        if not m.get("success"):
            die(f"backup/info: {json.dumps(m.get('error'))}")

        auto = [b for b in m["result"]["backups"]
                if b.get("with_automatic_settings")]
        if not auto:
            die("no automatic backups on the box")
        return max(auto, key=lambda b: b.get("date") or "")


def main():
    token = ha_token()
    b = asyncio.run(newest_automatic_backup(token))

    bid, name = b["backup_id"], b.get("name", "?")
    date = datetime.datetime.fromisoformat(b["date"])
    age_h = (datetime.datetime.now(date.tzinfo) - date).total_seconds() / 3600
    if age_h > MAX_AGE_HOURS:
        die(f"newest automatic backup {bid} is {age_h:.0f}h old "
            f"(HA stopped backing up?)")

    local = (b.get("agents") or {}).get("hassio.local") or {}
    if not local.get("protected"):
        die(f"backup {bid} is not encrypted -- refusing to ship it unprotected")
    expected = local.get("size") or 0
    if expected < 1_000_000:
        die(f"backup {bid} is implausibly small ({expected} bytes)")

    s3key = f"{PREFIX}/{date.date()}.tar"
    print(f"shipping {bid} ({name}, {expected/1e6:.0f} MB, {age_h:.1f}h old) "
          f"-> s3://{BUCKET}/{s3key}")

    conn = connect()
    conn.request("GET", f"/api/backup/download/{bid}?agent_id=hassio.local",
                 headers={"Authorization": f"Bearer {token}"})
    resp = conn.getresponse()
    if resp.status != 200:
        die(f"download returned HTTP {resp.status}")

    up = subprocess.Popen([AWS, "s3", "cp", "-", f"s3://{BUCKET}/{s3key}",
                           "--quiet"], stdin=subprocess.PIPE)
    sent = 0
    try:
        while chunk := resp.read(1 << 20):
            up.stdin.write(chunk)
            sent += len(chunk)
    except Exception as e:
        up.stdin.close(); up.wait()
        die(f"download failed after {sent} bytes: {e}")
    finally:
        conn.close()
    up.stdin.close()
    if up.wait() != 0:
        die(f"cloud-01 s3 cp exited {up.returncode}")

    if sent != expected:
        die(f"size mismatch: HA said {expected}, shipped {sent}")

    # Prove it landed, rather than trusting an exit code.
    r = subprocess.run([AWS, "s3api", "head-object", "--bucket", BUCKET,
                        "--key", s3key], capture_output=True, text=True)
    if r.returncode != 0:
        die("uploaded object not found in S3")
    landed = json.loads(r.stdout).get("ContentLength")
    if landed != expected:
        die(f"S3 object is {landed} bytes, expected {expected}")

    msg = f"OK {expected/1e6:.0f}MB {bid}"
    print(f"{datetime.datetime.now().isoformat()} ha-backup {msg} "
          f"-> s3://{BUCKET}/{s3key}")
    kuma("up", msg)


if __name__ == "__main__":
    main()
