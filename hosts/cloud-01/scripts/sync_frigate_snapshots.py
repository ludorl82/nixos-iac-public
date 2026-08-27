#!/usr/bin/env python3
"""Pull Frigate snapshot JPEGs from nas and archive new ones to S3.

nas holds a 31-day rolling mirror of gpu-02's Frigate snapshots
(synced separately, gpu-02 -> NAS). This script pulls that mirror down to
a local staging dir on cloud-01 via rsync, then uploads any file not already in
S3 to s3://frigate-snapshots-example-com/ad410-avant/ using the EC2
instance role (RoleAws). S3 is an accumulating long-term archive: nothing
is ever deleted here, unlike the 31-day local/NAS window.
"""
import logging
import os
import subprocess
import sys
import time

import boto3
import requests
import urllib3
from botocore.exceptions import BotoCoreError, ClientError

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

NAS_HOST = "192.0.2.65"
NAS_USER = "admin"
SSH_KEY = os.path.expanduser("~/.ssh/id_ed25519_nas_pull")
NAS_SRC = f"{NAS_USER}@{NAS_HOST}:/share/CACHEDEV1_DATA/frigate-backup/snapshots/ad410-avant/"
STAGING_DIR = "/opt/frigate-snapshots-staging/"
BUCKET = "frigate-snapshots-example-com"
PREFIX = "ad410-avant/"
REGION = "ca-central-1"
LOG_FILE = "/var/log/frigate_snapshot_sync.log"
PUSH_URL = "https://kuma.lab.example/api/push/EXAMPLEPUSHTOKEN"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)


def push(status, msg):
    # The push hairpins through Traefik back to the kuma pod on this same node;
    # that path intermittently stalls well past a short timeout (2026-07-25: 27
    # consecutive lost pushes on syncs that had actually succeeded). Retry
    # rather than let a healthy run report DOWN.
    if not PUSH_URL:
        return
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


def rsync_pull():
    os.makedirs(STAGING_DIR, exist_ok=True)
    ssh_cmd = f"ssh -i {SSH_KEY} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    cmd = ["rsync", "-a", "--delete", "-e", ssh_cmd, NAS_SRC, STAGING_DIR]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"rsync failed: {result.stderr}")


def list_s3_keys(s3):
    keys = set()
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=PREFIX):
        for obj in page.get("Contents", []):
            keys.add(obj["Key"])
    return keys


def main():
    try:
        rsync_pull()
    except RuntimeError as exc:
        logging.error("%s", exc)
        push("down", str(exc))
        return 1

    local_files = sorted(
        f for f in os.listdir(STAGING_DIR) if f.lower().endswith((".jpg", ".png"))
    )
    if not local_files:
        logging.info("No snapshot files present after rsync pull; nothing to do")
        push("up", "No snapshot files to sync")
        return 0

    s3 = boto3.client("s3", region_name=REGION)
    try:
        existing = list_s3_keys(s3)
    except (BotoCoreError, ClientError) as exc:
        logging.error("Failed to list existing S3 objects: %s", exc)
        push("down", f"list_objects_v2 failed: {exc}")
        return 1

    uploaded = 0
    for fname in local_files:
        key = PREFIX + fname
        if key in existing:
            continue
        path = os.path.join(STAGING_DIR, fname)
        content_type = "image/png" if fname.lower().endswith(".png") else "image/jpeg"
        try:
            s3.upload_file(path, BUCKET, key, ExtraArgs={"ContentType": content_type})
            uploaded += 1
        except (BotoCoreError, ClientError) as exc:
            logging.error("Upload failed for %s: %s", key, exc)
            push("down", f"Upload failed for {key}: {exc}")
            return 1

    logging.info(
        "Sync complete: %d local files, %d newly uploaded to s3://%s/%s",
        len(local_files), uploaded, BUCKET, PREFIX,
    )
    push("up", f"{uploaded} new snapshot(s) uploaded ({len(local_files)} total local)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
