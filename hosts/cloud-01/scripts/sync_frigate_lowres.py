#!/usr/bin/env python3
"""Pull low-res Frigate video segments from gpu-02 and archive new ones to S3.

gpu-02 runs a standalone ffmpeg (systemd unit frigate-lowres-feed.service)
that continuously re-encodes the ad410-avant go2rtc restream down to
640x480/~120kbps, no audio, in 5-minute segments, kept locally for only a
~12h safety buffer (pruned by cron on gpu-02). This script pulls new
segments down to a local staging dir on cloud-01 via rsync, then uploads any not
already in S3 to s3://frigate-snapshots-example-com/ad410-avant-lowres/
using the EC2 instance role (RoleAws). Unlike the full-res snapshot archive,
this prefix has a 3-day S3 lifecycle expiration rule -- this script never
deletes anything itself, S3 lifecycle handles pruning.
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

ENCODEUR_HOST = "192.0.2.98"  # gpu-02 (moved back from gpu-01 2026-07-24)
ENCODEUR_USER = "ludorl82"
SSH_KEY = os.path.expanduser("~/.ssh/id_ed25519_encodeur_pull")
REMOTE_SRC = f"{ENCODEUR_USER}@{ENCODEUR_HOST}:/home/ludorl82/opt/frigate/lowres/ad410-avant/"
STAGING_DIR = "/opt/frigate-lowres-staging/"
BUCKET = "frigate-snapshots-example-com"
PREFIX = "ad410-avant-lowres/"
REGION = "ca-central-1"
LOG_FILE = "/var/log/frigate_lowres_sync.log"
PUSH_URL = "https://kuma.lab.example/api/push/EXAMPLEPUSHTOKEN"

# Skip segments still likely being actively written by ffmpeg (5-min
# segment_time); only touch files whose last modification is older than this.
MIN_AGE_SECONDS = 360

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
    cmd = ["rsync", "-a", "--delete", "-e", ssh_cmd, REMOTE_SRC, STAGING_DIR]
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

    now = time.time()
    local_files = sorted(
        f for f in os.listdir(STAGING_DIR)
        if f.lower().endswith(".mp4")
        and (now - os.path.getmtime(os.path.join(STAGING_DIR, f))) >= MIN_AGE_SECONDS
    )
    if not local_files:
        logging.info("No finalized segments present after rsync pull; nothing to do")
        push("up", "No segments to sync")
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
        try:
            s3.upload_file(path, BUCKET, key, ExtraArgs={"ContentType": "video/mp4"})
            uploaded += 1
        except (BotoCoreError, ClientError) as exc:
            logging.error("Upload failed for %s: %s", key, exc)
            push("down", f"Upload failed for {key}: {exc}")
            return 1

    logging.info(
        "Sync complete: %d local segments, %d newly uploaded to s3://%s/%s",
        len(local_files), uploaded, BUCKET, PREFIX,
    )
    push("up", f"{uploaded} new segment(s) uploaded ({len(local_files)} total local)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
