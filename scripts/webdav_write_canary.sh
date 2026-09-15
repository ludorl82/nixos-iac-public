#!/bin/bash
# Proves the KeePass WebDAV can still be WRITTEN to, not merely read — and
# written to under the file NAMES a real client actually uses.
#
# Why this exists. Twice now an Apache authz pattern has stopped matching the
# temp file an atomic save creates, and every save began returning 403:
#
#   2026-09-05  the pattern missed `X.tmp.<digits>.kdbx` (KeePass 2.x) — four
#               days of silently failing saves, found only when a rotated
#               Cloudflare token never reached kp-get.
#   2026-09-14  anchoring that fix newly denied `X.kdbx.tmp` (KeePassXC) — the
#               laptop could not save.
#
# Both times `GET /ludovic.kdbx` answered 200, the pod stayed Healthy, ArgoCD
# stayed Synced, and no monitor said a word. The first version of this script
# would not have caught the second outage either: it wrote only `/_canary`, a
# path of its own, which proves the service accepts *a* write but not that it
# accepts the name YOUR client writes. An authz rule matched by pattern has as
# many holes as there are clients, so the canary now exercises every shape:
#
#   /_canary                      the plain scratch path
#   /_canary.tmp.<digits>.kdbx    the KeePass 2.x temp shape
#   /_canary.kdbx.tmp             the KeePassXC temp shape
#   /_canary.kdbx.tmp.nope        negative control — MUST still be refused
#
# Each write is a nonce that is read back and compared: a PUT returning 201
# while storing nothing, or storing something else, fails here.
#
# Why `_canary` and never a real basename. A real client saves by PUT temp ->
# DELETE target -> MOVE temp over target. If this script wrote `ludovic.kdbx.tmp`
# while the laptop was mid-save, the client's MOVE would rename OUR nonce over
# `ludovic.kdbx` and destroy the database while reporting success. So the
# basename is one that can never be a database, and this script never MOVEs.
# The tradeoff is deliberate: what broke twice is the SHAPE of the temp name,
# and the shape is what this exercises, through the same tunnel, the same
# Traefik basic auth and the same authz rules a real save goes through.
# `_canary` is in the `LocationMatch` alternation in k3s-iac for exactly this.
#
# Runs on pi-02 (jumphost), NOT in the cluster it watches: the WebDAV pod is
# pinned to the cloud-01 node, so a cluster-side check would share the fate of the
# thing it monitors. Kuma is a PUSH monitor for the same reason — if this
# script stops running at all, the absence of the heartbeat is the alert.
#
# Credentials come from KeePass on every run via kp-get, never from disk —
# same rule as wan_ip_cloudflare_sync.sh.

set -euo pipefail

BASE="https://vault.family.example"
KP_ENTRY="Keepass Server"
KP_USER="keepass2"
PUSH_URL="https://kuma.lab.example/api/push/EXAMPLEPUSHTOKEN"

# vault.family.example carries a WAF rate limit of 20 requests / 10 s
# (cloudflare-iac live/rulesets.tf, kp-webdav-ratelimit). This run makes ten,
# so it pauses between shapes rather than firing them all in one burst.
SPACING=2

push() {
    local status="$1" msg="$2" http_code rc
    set +e
    http_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" -G "$PUSH_URL" \
        --data-urlencode "status=$status" --data-urlencode "msg=$msg" 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] || [ "$http_code" != "200" ]; then
        logger -t webdav_write_canary "push failed: curl_rc=$rc http_code=$http_code status=$status"
    fi
}

fail() {
    logger -t webdav_write_canary "FAILED: $1" 2>/dev/null || true
    push down "$1"
    exit 1
}

PW=$(/usr/local/bin/kp-get "$KP_ENTRY" 2>/dev/null) || fail "kp-get could not read '$KP_ENTRY'"
[ -n "$PW" ] || fail "kp-get returned an empty password for '$KP_ENTRY'"

# PUT a nonce, read it back, compare, clean up. $1 = path, $2 = what a failure
# here means in plain words, so the alert names the broken client, not a URL.
check_writable() {
    local path="$1" label="$2" nonce code body url
    # assigned separately: `local` expands every word before it assigns any of
    # them, so `url="$BASE$path"` on the line above would read $path unset.
    url="$BASE$path"

    # a nonce, so a stale body served from anywhere cannot pass for a fresh write
    nonce="canary $(date -u +%Y-%m-%dT%H:%M:%SZ) $$-${RANDOM} $path"

    code=$(curl -s -u "$KP_USER:$PW" -X PUT --data "$nonce" \
        -o /dev/null -w "%{http_code}" --max-time 20 "$url") \
        || fail "PUT $path failed (network/TLS) — $label"
    case "$code" in
        200|201|204) ;;
        403) fail "PUT $path refused 403 — the authz rule no longer allows this name. $label" ;;
        401) fail "PUT $path refused 401 — basic auth rejected; the WebDAV credential may have rotated" ;;
        *)   fail "PUT $path returned $code — $label" ;;
    esac

    body=$(curl -s -u "$KP_USER:$PW" --max-time 20 "$url") \
        || fail "GET after PUT of $path failed (network/TLS)"
    # The whole point: a write that reports success but stores nothing, or
    # stores something else, must not pass. Compare, do not trust the status.
    [ "$body" = "$nonce" ] || fail "read-back mismatch on $path — the write did not land. $label"

    code=$(curl -s -u "$KP_USER:$PW" -X DELETE -o /dev/null -w "%{http_code}" --max-time 20 "$url") || true
    case "$code" in
        200|204|404) ;;
        # Not fatal: the write path — the thing being monitored — is proven by
        # here. A canary left behind is untidy, not an outage, and failing the
        # check for it would cry wolf about the wrong thing.
        *) logger -t webdav_write_canary "cleanup DELETE of $path returned $code (write path is fine)" 2>/dev/null || true ;;
    esac
}

check_writable "/_canary" \
    "the scratch path itself is refused — the whole write path is down"
sleep "$SPACING"

check_writable "/_canary.tmp.$(( RANDOM * 1000 + RANDOM )).kdbx" \
    "KeePass 2.x saves would 403 on their temp file (this is the 2026-09-05 outage)"
sleep "$SPACING"

check_writable "/_canary.kdbx.tmp" \
    "KeePassXC saves would 403 on their temp file (this is the 2026-09-14 outage)"
sleep "$SPACING"

# The other direction: the rule must stay TIGHT. A pattern loosened until
# everything matches would make every check above pass while exposing the
# whole of /data to an authenticated caller, so assert a refusal too.
code=$(curl -s -u "$KP_USER:$PW" -X PUT --data x \
    -o /dev/null -w "%{http_code}" --max-time 20 "$BASE/_canary.kdbx.tmp.nope") \
    || fail "negative control request failed (network/TLS)"
if [ "$code" != "403" ]; then
    # It was accepted, so it exists: take it back out before alerting, or a
    # loosened pattern leaves a new file behind on every run.
    curl -s -u "$KP_USER:$PW" -X DELETE -o /dev/null --max-time 20 "$BASE/_canary.kdbx.tmp.nope" || true
    fail "negative control: PUT /_canary.kdbx.tmp.nope returned $code, expected 403 — the authz pattern has been loosened too far"
fi

logger -t webdav_write_canary "write canary OK (scratch + both temp shapes + negative control)" 2>/dev/null || true
push up "write canary OK — /_canary, KeePass 2.x and KeePassXC temp shapes, and a refused path"
