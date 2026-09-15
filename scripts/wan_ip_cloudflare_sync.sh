#!/bin/bash
# Detects home WAN IP changes (read remotely from router) and keeps the
# Cloudflare account IP list ("whitelist", used by the Kuma Access policy +
# any other IP-gated Access apps added later) in sync, so admin dashboards
# behind Cloudflare Access stay reachable without manual intervention after
# an ISP IP change. Does NOT touch WireGuard -- that already self-heals via
# endpoint roaming (PersistentKeepalive on both sides).
#
# Runs on console-vm (not router) specifically so the Cloudflare API token
# can be fetched fresh from KeePass each run via kp-get, never written to
# disk -- see credentials.md's "no plaintext secret files" rule.

set -euo pipefail

STATEFILE="$HOME/.wan_ip_cloudflare_sync_last"
PUSH_URL="https://kuma.lab.example/api/push/EXAMPLEPUSHTOKEN"
ACCT="02d1d1c280f4596af643f9f9395588d0"
LIST_ID="ea4e02223aa04935a7e7c14435a59d7b"
AWS_IP="203.0.113.7"
IPV6_ITEM_COMMENT="videotron ipv6"

# The Cloudflare Access bypass that lets the house reach dev.labodeludo.dev
# without the OTP screen (cloudflare-iac, live/access-apps.tf, resource
# home_ip_bypass). It is maintained HERE rather than in tofu because the v4
# address below is the ISP's to change; tofu declares the policy and carries
# `lifecycle { ignore_changes = [include] }` so the two do not fight.
#
# It cannot simply point at $LIST_ID: Access documents only literal "IP
# ranges", and a policy referencing the rules-list id applied cleanly and
# matched nothing — the login page kept coming back while Cloudflare reported
# the caller as the very address the list held. Silent no-op, cost an
# afternoon, hence the duplication of the addresses into the policy.
ACCESS_POLICY_ID="00000000-0000-0000-0000-000000000000"
ACCESS_POLICY_NAME="Home IP bypass (staging)"
IPV6_PREFIX="2001:db8:9:8740:b500::/56"

push() {
    local status="$1" msg="$2" http_code rc
    set +e
    http_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" -G "$PUSH_URL" --data-urlencode "status=$status" --data-urlencode "msg=$msg" 2>/tmp/wan_ip_cloudflare_sync_curl_err.$$)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] || [ "$http_code" != "200" ]; then
        logger -t wan_ip_cloudflare_sync "push failed: curl_rc=$rc http_code=$http_code status=$status stderr=$(cat /tmp/wan_ip_cloudflare_sync_curl_err.$$ 2>/dev/null)"
    fi
    rm -f /tmp/wan_ip_cloudflare_sync_curl_err.$$
}

current_ip=$(ssh -o ConnectTimeout=5 router "ifconfig mvneta0.4090" | awk '/inet /{print $2; exit}')
if [ -z "$current_ip" ]; then
    push down "Could not read WAN IP from router"
    exit 1
fi

CF_TOKEN=$(/usr/local/bin/kp-get "Cloudflare Kuma Access IP Sync")

# Reconcile the Access bypass on EVERY run, not only when the IP changes.
# The list update below is edge-triggered because rewriting it is a whole PUT;
# this one is a cheap GET that usually decides to do nothing, and being
# level-triggered means it self-heals — a hand edit in the dashboard, a failed
# write, or a policy that never got seeded is corrected on the next tick
# instead of waiting for the ISP to renumber us. Prints nothing when it agrees.
reconcile_access_policy() {
    local want got body result ok
    want=$(jq -cn --arg v4 "$1/32" --arg v6 "$IPV6_PREFIX" \
        '[{ip:{ip:$v4}},{ip:{ip:$v6}}]')

    got=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
        "https://api.cloudflare.com/client/v4/accounts/$ACCT/access/policies/$ACCESS_POLICY_ID" \
        | jq -c '.result.include // empty')

    [ "$got" = "$want" ] && return 0

    body=$(jq -cn --arg n "$ACCESS_POLICY_NAME" --argjson inc "$want" \
        '{name:$n, decision:"bypass", include:$inc}')
    result=$(curl -s -X PUT -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/accounts/$ACCT/access/policies/$ACCESS_POLICY_ID" \
        -d "$body")

    ok=$(echo "$result" | jq -r '.success')
    if [ "$ok" = "true" ]; then
        logger -t wan_ip_cloudflare_sync "Access bypass policy updated to $1/32 + $IPV6_PREFIX" 2>/dev/null || true
        return 0
    fi
    logger -t wan_ip_cloudflare_sync "Access bypass policy update FAILED: $(echo "$result" | jq -c '.errors')" 2>/dev/null || true
    return 1
}

access_msg=""
if ! reconcile_access_policy "$current_ip"; then
    access_msg=" (Access bypass update FAILED)"
fi

last_ip=""
[ -f "$STATEFILE" ] && last_ip=$(cat "$STATEFILE")

if [ "$current_ip" = "$last_ip" ]; then
    # A failed Access write must not report success just because the list half
    # had nothing to do — that is the shape of bug this lab keeps finding.
    if [ -n "$access_msg" ]; then
        push down "No change, WAN IP still $current_ip$access_msg"
        exit 1
    fi
    push up "No change, WAN IP still $current_ip"
    exit 0
fi

existing=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$ACCT/rules/lists/$LIST_ID/items")

new_items=$(echo "$existing" | jq -c --arg new_ip "$current_ip" --arg aws_ip "$AWS_IP" --arg v6c "$IPV6_ITEM_COMMENT" '
  [.result[] | select(.ip != $new_ip and .ip != $aws_ip and (.comment != $v6c)) | {ip, comment}] as $other
  | $other + [{ip: $aws_ip, comment: "cloud-01 public IP - same-box loopback fallback, static"},
               {ip: $new_ip, comment: "home WAN (router) - kuma/private-service access, auto-synced"}]
  + [.result[] | select(.comment == $v6c) | {ip, comment}]
')

result=$(curl -s -X PUT -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/$ACCT/rules/lists/$LIST_ID/items" \
    -d "$new_items")

ok=$(echo "$result" | jq -r '.success')
if [ "$ok" = "true" ] && [ -z "$access_msg" ]; then
    echo "$current_ip" > "$STATEFILE"
    logger -t wan_ip_cloudflare_sync "WAN IP changed ${last_ip:-<none>} -> $current_ip, Cloudflare list updated" 2>/dev/null || true
    push up "WAN IP changed ${last_ip:-<none>} -> $current_ip, Cloudflare list + Access bypass updated"
elif [ "$ok" = "true" ]; then
    # List moved, Access did not. Deliberately do NOT write the statefile: the
    # next run must retry rather than conclude there is nothing to do.
    logger -t wan_ip_cloudflare_sync "WAN IP changed to $current_ip, list updated but Access bypass FAILED" 2>/dev/null || true
    push down "WAN IP changed to $current_ip, list updated$access_msg"
else
    logger -t wan_ip_cloudflare_sync "WAN IP changed to $current_ip but Cloudflare update FAILED" 2>/dev/null || true
    push down "WAN IP changed to $current_ip but Cloudflare update failed"
fi
