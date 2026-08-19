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

last_ip=""
[ -f "$STATEFILE" ] && last_ip=$(cat "$STATEFILE")

if [ "$current_ip" = "$last_ip" ]; then
    push up "No change, WAN IP still $current_ip"
    exit 0
fi

CF_TOKEN=$(/usr/local/bin/kp-get "Cloudflare Kuma Access IP Sync")

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
if [ "$ok" = "true" ]; then
    echo "$current_ip" > "$STATEFILE"
    logger -t wan_ip_cloudflare_sync "WAN IP changed ${last_ip:-<none>} -> $current_ip, Cloudflare list updated" 2>/dev/null || true
    push up "WAN IP changed ${last_ip:-<none>} -> $current_ip, Cloudflare list updated"
else
    logger -t wan_ip_cloudflare_sync "WAN IP changed to $current_ip but Cloudflare update FAILED" 2>/dev/null || true
    push down "WAN IP changed to $current_ip but Cloudflare update failed"
fi
