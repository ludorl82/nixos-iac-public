#!/usr/bin/env python3
"""Daily encrypted backup of cloud-01's service-critical state to S3.

Tars .ssh, /opt/scripts, and the k3s server state (cluster PKI + token +
the newest twice-daily etcd snapshot -- cloud-01 is the sole control-plane/etcd
member since cp-1's decommission, so this is the only off-box copy of
the cluster identity; losing it means re-joining all 8 agents). The live
db/ dir is deliberately NOT tarred: it changes underneath tar, the k3s
etcd snapshots are the consistent capture. GPG-encrypts the stream and
uploads via the EC2 instance role (RoleAws, reached via IMDS -- no
cloud-01-cli/~/.cloud-01/credentials on this host, unlike the other backed-up
hosts).

2026-07-25 (NixOS conversion): dropped the Grafana volume snapshot --
loki-docker_grafana-data was retired with the Ubuntu install (Grafana
lives in the k3s logging namespace on an NFS PVC now); added the k3s
server state in its place.
"""
import datetime
import io
import logging
import os
import subprocess
import sys
import time
import tarfile

import boto3
import requests
import urllib3
from botocore.exceptions import BotoCoreError, ClientError

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

BUCKET = "homelab-backups-example-com"
REGION = "ca-central-1"
HOST = "cloud-01"
LOG_FILE = "/var/log/homelab_backup.log"
PUSH_URL = "http://198.51.100.7:3001/api/push/EXAMPLEPUSHTOKEN"
K3S_SERVER = "/var/lib/rancher/k3s/server"
PATHS = ["/home/ludorl82/.ssh", "/opt/scripts"]

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)


def push(status, msg):
    # The push hairpins through Traefik back to the kuma pod; that path
    # intermittently stalls well past a short timeout, losing the heartbeat
    # for a job that actually succeeded. Retry rather than report DOWN.
    last = None
    for attempt in range(3):
        try:
            resp = requests.get(
                PUSH_URL, params={"status": status, "msg": msg}, timeout=15, verify=False
            )
            if resp.status_code == 200:
                return
            last = f"HTTP {resp.status_code} {resp.text[:200]}"
        except requests.RequestException as exc:
            last = str(exc)
        if attempt < 2:
            time.sleep(3)
    logging.warning("Kuma push failed after 3 attempts: %s", last)


def fetch_passphrase():
    result = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=5", "-i", "/home/ludorl82/.ssh/homelab_backup_kp",
         "jumphost.lab.example"],
        capture_output=True, text=True, timeout=15,
    )
    return result.stdout.strip()


def snapshot_k3s_server():
    """Root-only k3s state as an in-memory tar: token, cred/, tls/, and the
    newest etcd snapshot (k3s writes one every 12h; consistent by design,
    unlike the live db/ dir)."""
    newest = subprocess.run(
        ["sudo", "sh", "-c", "ls -t %s/db/snapshots | head -1" % K3S_SERVER],
        capture_output=True, text=True,
    )
    snap_name = newest.stdout.strip()
    if newest.returncode != 0 or not snap_name:
        logging.error("no etcd snapshot found: %s", newest.stderr[:300])
        return None
    result = subprocess.run(
        ["sudo", "tar", "-cf", "-", "-C", K3S_SERVER,
         "token", "cred", "tls", "db/snapshots/%s" % snap_name],
        capture_output=True,
    )
    if result.returncode != 0:
        logging.error("k3s server snapshot failed: %s", result.stderr.decode(errors="replace")[:300])
        return None
    logging.info("k3s server state captured (etcd snapshot: %s)", snap_name)
    return result.stdout


def main():
    k3s_tar = snapshot_k3s_server()
    if k3s_tar is None:
        push("down", "k3s server snapshot failed")
        return 1

    skipped = []

    def keep_readable(tarinfo):
        # tar.add() dies on the first member it cannot open, which takes the
        # whole backup down for one stray file -- and it dies BEFORE the
        # push() below, so the only signal is the heartbeat expiring hours
        # later. Skip what we cannot read, record it, and let the caller
        # report the backup as degraded (2026-08-08: a root-owned mode-751
        # .bak dropped in /opt/scripts by an edit did exactly this).
        #
        # arcname is path.lstrip("/") and recursion keeps that relationship,
        # so the real path is always "/" + tarinfo.name.
        real = "/" + tarinfo.name
        need = os.R_OK | os.X_OK if tarinfo.isdir() else os.R_OK
        if (tarinfo.isreg() or tarinfo.isdir()) and not os.access(real, need):
            skipped.append(real)
            logging.warning("Unreadable, skipped: %s", real)
            return None
        return tarinfo

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for path in PATHS:
            tar.add(path, arcname=path.lstrip("/"), filter=keep_readable)
        info = tarfile.TarInfo(name="k3s-server.tar")
        info.size = len(k3s_tar)
        tar.addfile(info, io.BytesIO(k3s_tar))
    data = buf.getvalue()

    passphrase = fetch_passphrase()
    if not passphrase:
        logging.error("Could not fetch passphrase from KeePass (via jumphost)")
        push("down", "passphrase fetch failed")
        return 1

    date = datetime.datetime.now().strftime("%Y-%m-%d")
    key = "%s/%s.tar.gz.gpg" % (HOST, date)

    pass_r, pass_w = os.pipe()
    os.write(pass_w, passphrase.encode())
    os.close(pass_w)
    gpg = subprocess.run(
        ["gpg", "--batch", "--yes", "--symmetric", "--cipher-algo", "AES256",
         "--compress-algo", "zlib", "--passphrase-fd", str(pass_r)],
        input=data, capture_output=True, pass_fds=(pass_r,),
    )
    os.close(pass_r)
    if gpg.returncode != 0:
        logging.error("gpg encryption failed: %s", gpg.stderr.decode(errors="replace")[:300])
        push("down", "gpg encryption failed")
        return 1

    try:
        s3 = boto3.client("s3", region_name=REGION)
        s3.put_object(Bucket=BUCKET, Key=key, Body=gpg.stdout, ContentType="application/octet-stream")
    except (BotoCoreError, ClientError) as exc:
        logging.error("Upload failed for s3://%s/%s: %s", BUCKET, key, exc)
        push("down", "upload failed: %s" % exc)
        return 1

    logging.info("Backed up -> s3://%s/%s (%d bytes)", BUCKET, key, len(gpg.stdout))

    # An incomplete archive uploaded successfully is still a failed backup.
    # Report it DOWN rather than UP: the object exists (better than nothing,
    # and it holds the k3s identity), but something is missing and only a
    # human can decide whether that something mattered.
    if skipped:
        shown = ", ".join(skipped[:3]) + ("..." if len(skipped) > 3 else "")
        msg = "DEGRADED: uploaded %s/%s but %d unreadable: %s" % (
            BUCKET, key, len(skipped), shown)
        logging.error(msg)
        push("down", msg)
        return 1

    push("up", "OK -> s3://%s/%s" % (BUCKET, key))
    return 0


if __name__ == "__main__":
    sys.exit(main())
