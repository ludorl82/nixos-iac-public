#!/usr/bin/env python3
"""Daily backup of KeePass databases to S3.

Tars the *.kdbx files from the numeriseur keepass docker volume and uploads
them to s3://backups-portecles-example-com/keepass2_YYYYMMDD.tgz using the
EC2 instance role (RoleNumeriseur, reached via IMDS).

Run as root via cron: some databases are mode 640 owned by uid 1006, so an
unprivileged user cannot read them all.
"""
import datetime
import glob
import io
import logging
import os
import sys
import time
import tarfile

import boto3
import requests
import urllib3
from botocore.exceptions import BotoCoreError, ClientError

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

SRC_DIR = "/var/lib/keepass"
BUCKET = "backups-portecles-example-com"
REGION = "ca-central-1"
LOG_FILE = "/var/log/keepass_backup.log"
PUSH_URL = "https://kuma.lab.example/api/push/EXAMPLEPUSHTOKEN"

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


def main():
    files = sorted(glob.glob(os.path.join(SRC_DIR, "*.kdbx")))
    if not files:
        logging.error("No .kdbx files found in %s; aborting", SRC_DIR)
        push("down", "No .kdbx files found in %s" % SRC_DIR)
        return 1

    date = datetime.datetime.now().strftime("%Y%m%d")
    key = "keepass2_%s.tgz" % date

    # Build the gzipped tar in memory (databases total only a few MB).
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for path in files:
            tar.add(path, arcname=os.path.basename(path))
    data = buf.getvalue()

    try:
        s3 = boto3.client("s3", region_name=REGION)
        s3.put_object(
            Bucket=BUCKET,
            Key=key,
            Body=data,
            ContentType="application/gzip",
        )
    except (BotoCoreError, ClientError) as exc:
        logging.error("Upload failed for s3://%s/%s: %s", BUCKET, key, exc)
        push("down", "Upload failed for s3://%s/%s: %s" % (BUCKET, key, exc))
        return 1

    logging.info(
        "Backed up %d databases (%d bytes) to s3://%s/%s",
        len(files), len(data), BUCKET, key,
    )
    push("up", "Backed up %d databases to s3://%s/%s" % (len(files), BUCKET, key))
    return 0


if __name__ == "__main__":
    sys.exit(main())
