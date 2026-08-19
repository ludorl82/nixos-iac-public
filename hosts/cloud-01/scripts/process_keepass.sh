#!/bin/bash
# $1 = filename that triggered the event

exec >> /var/log/keepass_domain_hash.log 2>&1

alert_trigger_failure() {
  local kind="$1" rc="$2"
  local debounce_file="/tmp/keepass_trigger_alert_${kind}.last"
  local now
  now=$(date +%s)
  if [[ -f "$debounce_file" ]]; then
    local last
    last=$(cat "$debounce_file")
    if (( now - last < 600 )); then
      return
    fi
  fi
  echo "$now" > "$debounce_file"
  local token
  token=$(systemd-creds decrypt --name=ntfy_keepass_pipeline /etc/credstore/ntfy_keepass_pipeline.cred -) || return
  curl -s -X POST https://ntfy.pub.example.com/alerts \
    -H "Authorization: Bearer ${token}" \
    -H "Title: KeePass sync pipeline FAILED" \
    -H "Priority: urgent" \
    -H "Tags: warning,closed_lock_with_key" \
    -d "KeePass pipeline for ${kind} exited ${rc}. Either the SSH never landed (pipeline did NOT run -- check known_hosts/connectivity for jumphost.lab.example) or it ran and reported a failure, e.g. the Gmail-filter phase skipped. Log: pi-02:/var/log/keepass_domain_hash.log" \
    >/dev/null
}

case "$1" in
  ludovic.kdbx)
    LOCKFILE=/tmp/process_keepass.lock
    exec 9>"$LOCKFILE"
    flock -n 9 || exit 0
    ssh -i /root/.ssh/keepass_trigger -o ConnectTimeout=5 ludorl82@jumphost.lab.example
    rc=$?
    [[ $rc -ne 0 ]] && alert_trigger_failure ludovic "$rc"
    ;;
  family.kdbx)
    LOCKFILE=/tmp/process_keepass_family.lock
    exec 9>"$LOCKFILE"
    flock -n 9 || exit 0
    ssh -i /root/.ssh/keepass_trigger_family -o ConnectTimeout=5 ludorl82@jumphost.lab.example
    rc=$?
    [[ $rc -ne 0 ]] && alert_trigger_failure family "$rc"
    ;;
  *)
    exit 0
    ;;
esac
