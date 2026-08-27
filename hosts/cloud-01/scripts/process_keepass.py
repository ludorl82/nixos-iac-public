#!/usr/bin/env python3
import hashlib
import json
import logging
import base64
import tempfile
import os
import time
from datetime import datetime, timezone
from urllib.parse import urlparse

import boto3
from pykeepass import PyKeePass

KDBX_PATH = "/var/lib/keepass/ludovic.kdbx"
SECRET_NAME = "keepass/credentials"
REGION = "ca-central-1"
LOG_FILE = "/var/log/keepass_domain_hash.log"
SHORT_URL_GROUP = "URLs courtes"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

def get_secret():
    client = boto3.client("secretsmanager", region_name=REGION)
    response = client.get_secret_value(SecretId=SECRET_NAME)
    return json.loads(response["SecretString"])

def extract_domain(url):
    try:
        parsed = urlparse(url if "://" in url else "https://" + url)
        host = parsed.hostname or ""
        if host.startswith("www."):
            host = host[4:]
        return host.lower()
    except Exception:
        return None

def sync_short_urls(kp):
    s3 = boto3.client("s3", region_name=REGION)
    group = kp.find_groups(name=SHORT_URL_GROUP, first=True)
    if not group:
        logging.info("Group '%s' not found, skipping short URL sync.", SHORT_URL_GROUP)
        return
    for entry in group.entries:
        title = entry.title or ""
        url = entry.url
        if "/" not in title or not url:
            logging.warning("Skipping short URL entry '%s': title must be 'domain/key' and URL must be set.", title)
            continue
        bucket, key = title.split("/", 1)
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=b"",
            ContentType="binary/octet-stream",
            WebsiteRedirectLocation=url,
            ACL="public-read",
        )
        logging.info("Set S3 redirect %s/%s -> %s", bucket, key, url)

def main():
    logging.info("Starting domain hash update for %s", KDBX_PATH)
    secret = get_secret()
    password = secret["password"]
    keyfile_b64 = secret["keyfile_b64"]

    keyfile_tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".key")
    try:
        keyfile_tmp.write(base64.b64decode(keyfile_b64))
        keyfile_tmp.close()

        kp = PyKeePass(KDBX_PATH, password=password, keyfile=keyfile_tmp.name)

        modified = 0
        for entry in kp.entries:
            if not entry.url:
                continue
            if entry.get_custom_property("domain_hash") is not None and entry.get_custom_property("domain_email") is not None:
                continue
            domain = extract_domain(entry.url)
            if not domain:
                continue
            domain_hash = hashlib.sha256(domain.encode()).hexdigest()[-7:]
            entry.set_custom_property("domain_hash", domain_hash)
            entry.set_custom_property("domain_email", f"ludo_{domain_hash}@example.com")
            entry.touch(modify=True)
            logging.info("Set domain_hash=%s domain_email=ludo_%s@example.com for entry '%s' (domain: %s)", domain_hash, domain_hash, entry.title, domain)
            modified += 1

        if modified > 0:
            kp.save()
            logging.info("Saved database, %d entries updated.", modified)
        else:
            logging.info("No new entries to update.")

        sync_short_urls(kp)
    finally:
        os.unlink(keyfile_tmp.name)

if __name__ == "__main__":
    main()
