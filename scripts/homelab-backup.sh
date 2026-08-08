#!/bin/bash
# Daily encrypted backup of console-vm's service-critical state to S3.
set -uo pipefail

BUCKET="homelab-backups-example-com"
HOST="$(hostname -s)"
DATE="$(date +%F)"
AWS=/run/current-system/sw/bin/cloud-01  # was ~/.local/bin/cloud-01: a Debian CLI from the Pi 4, unrunnable on NixOS (exit 127)
# One push monitor per host — a shared URL would let one host's green mask
# the other's absence. pi-02 = Kuma "Homelab Backup (pi-02)", console-vm =
# "Homelab Backup (console-vm VM)".
case "$HOST" in
  pi-02)  KUMA_PUSH_URL="http://198.51.100.7:3001/api/push/EXAMPLEPUSHTOKEN" ;;
  console-vm) KUMA_PUSH_URL="http://198.51.100.7:3001/api/push/EXAMPLEPUSHTOKEN" ;;
  *)        KUMA_PUSH_URL="" ;;
esac
CRONTMP="/tmp/.homelab-backup-crontab.$$"

cleanup() { rm -f "$CRONTMP"; }
trap cleanup EXIT

cd "$HOME" || exit 1
crontab -l > "$CRONTMP" 2>/dev/null || true

PASSPHRASE="$(/usr/local/bin/kp-get "Homelab Backup Passphrase")"
if [ -z "$PASSPHRASE" ]; then
  echo "$(date -Is) backup FAILED: could not fetch passphrase from KeePass" >&2
  [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 "${KUMA_PUSH_URL}?status=down&msg=passphrase+fetch+failed&ping=" >/dev/null 2>&1
  exit 1
fi

# Note: /opt/scripts is stored with its full path (tar strips the leading
# "/" per GNU tar default), so on restore it lands back at opt/scripts/...
# relative to the extraction root -- extract with `tar -C / ...` to put it
# back at /opt/scripts directly.
#
# The list is a superset across the two hosts that run this (pi-02 the
# jumphost, console-vm the console VM) -- /opt/scripts is jumphost-only, for
# example. Prune what this host doesn't have, LOUDLY: with pipefail a
# missing member fails the whole run, and silence would hide a real loss.
WANT=".claude .claude.json
.cloud-01 .ssh .kube
.config/onedrive .config/gh
OneDrive
.keepass_password .keepass_family_password
.forwardemail_api_key
.keepass_gmail_filters.json
.keepass_family_gmail_filters.json .keepass_family_gmail_filters_prlea56.json
.keepass_family_regex_aliases.json .keepass_regex_aliases.json
.keepass_short_urls.json
.gmail_token_ludorl82.json .gmail_token_ludoviclamarre.json .gmail_token_prlea56.json
.cf-pages-ci-token .cf-pages-setup-token
.shell-scripts alloy numeriseur-docker logs
scripts /opt/scripts"
MEMBERS=""
for m in $WANT; do
  if [ -e "$m" ]; then MEMBERS="$MEMBERS $m"; else echo "$(date -Is) skipping absent member: $m" >&2; fi
done

# shellcheck disable=SC2086
tar --sort=name -czf - $MEMBERS "$CRONTMP" \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-fd 3 3<<<"$PASSPHRASE" \
  | "$AWS" s3 cp - "s3://${BUCKET}/${HOST}/${DATE}.tar.gz.gpg"

STATUS=$?

# Size floor: the pi-02/ prefix holds 4.8 KB "successes" from 2026-07 --
# a tar that lost its inputs still uploads and reports OK. Anything under
# 1 MB cannot be a real backup of this home; treat it as a failure.
if [ "$STATUS" -eq 0 ]; then
  SIZE=$("$AWS" s3api head-object --bucket "$BUCKET" --key "${HOST}/${DATE}.tar.gz.gpg" --query ContentLength --output text 2>/dev/null || echo 0)
  if [ "${SIZE:-0}" -lt 1048576 ]; then
    echo "$(date -Is) backup FAILED size floor: object is ${SIZE} bytes (< 1 MB)" >&2
    [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 "${KUMA_PUSH_URL}?status=down&msg=size+floor+${SIZE}+bytes&ping=" >/dev/null 2>&1
    exit 1
  fi
fi

if [ "$STATUS" -eq 0 ]; then
  echo "$(date -Is) backup OK -> s3://${BUCKET}/${HOST}/${DATE}.tar.gz.gpg"
  [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 "${KUMA_PUSH_URL}?status=up&msg=OK&ping=" >/dev/null 2>&1
else
  echo "$(date -Is) backup FAILED (exit $STATUS)" >&2
  [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 "${KUMA_PUSH_URL}?status=down&msg=backup+failed&ping=" >/dev/null 2>&1
fi
exit "$STATUS"
