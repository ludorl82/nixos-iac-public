#!/usr/bin/env bash
# Tests for labo-lire.sh — Qwen's only road to the lab's hosts, and it must
# be a read-only road. ssh is replaced by a fake that records what it would
# have run, so nothing leaves the machine.
#
# Proven: every read in the allowlist reaches the host, quoted word by word;
# every write, every shell metacharacter, every secret-looking path and every
# command outside the list is refused BEFORE ssh is started (exit 64).
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
L="$SCRIPTS/labo-lire.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lire-test.XXXXXX"); trap 'rm -rf "$ROOT"' EXIT
cat > "$ROOT/ssh" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/calls"; echo "ok-remote"
F
chmod +x "$ROOT/ssh"; export LABO_SSH="$ROOT/ssh"
pass=0; failed=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
allowed() { : > "$ROOT/calls"; out=$("$L" "$@" 2>&1); rc=$?
  [ $rc -eq 0 ] && [ -s "$ROOT/calls" ] && ok "allowed: $*" || bad "should be allowed: $* (rc=$rc, $out)"; }
refused() { : > "$ROOT/calls"; out=$("$L" "$@" 2>&1); rc=$?
  [ $rc -eq 64 ] && [ ! -s "$ROOT/calls" ] && ok "refused: $*" || bad "should be refused before ssh: $* (rc=$rc, $out)"; }

printf '\n\033[1m== reads\033[0m\n'
allowed worker2 uptime
allowed bob nvidia-smi --query-gpu=name,memory.used --format=csv
allowed bob nvidia-smi
allowed luna systemctl status k3s
allowed luna systemctl --failed
allowed coquille journalctl -u qwen-voice-bridge -n 50 --no-pager
allowed vega cat /proc/mdstat
allowed vega df -h
allowed bob docker ps
allowed bob virsh list --all
allowed worker2 ip route show
allowed worker2 tail -n 20 /var/log/messages
allowed worker2 grep -i error /var/log/messages
allowed worker2 tail -n 80 /home/ludorl82/logs/weekly-updates.log
allowed worker2 grep -n FAILED /home/ludorl82/logs/weekly-updates.log
allowed bob zpool status
allowed worker2 hostname
allowed worker2 date

printf '\n\033[1m== writes are refused\033[0m\n'
refused luna systemctl restart k3s
refused luna systemctl stop comin
refused bob docker rm -f frigate
refused bob docker run alpine
refused worker2 cat /home/ludorl82/logs/../.bash_history
refused worker2 cat /var/log/../../home/ludorl82/nixos-iac/flake.nix
refused worker2 cat /home/ludorl82/notes.txt
refused worker2 cat /home/ludorl82/logs/../.ssh/config
refused bob virsh destroy arcade1
refused bob virsh start worker5
refused bob nvidia-smi -r
refused bob nvidia-smi -pl 100
refused worker2 ip route add 198.18.0.0/15 dev lo
refused worker2 ip link set eth0 down
refused worker2 journalctl --vacuum-time=1d
refused worker2 hostname pwned
refused worker2 date -s 2020-01-01
refused bob zpool destroy tank
refused bob mdadm --stop /dev/md0
refused worker2 tail -f /var/log/messages
refused worker2 rm -rf /tmp/x
refused worker2 sudo cat /etc/shadow
refused worker2 kp-get Kuma
refused worker2 bash -c id

printf '\n\033[1m== chaining and secrets are refused\033[0m\n'
refused worker2 uptime ';' rm -rf /
refused worker2 'uptime; reboot'
refused worker2 cat '/proc/$(reboot)'
refused worker2 cat /etc/passwd '|' sh
refused worker2 cat /etc/ssh/ssh_host_ed25519_key
refused worker2 cat /var/lib/qwen-voice/env
refused worker2 cat /home/ludorl82/.kube/config
refused worker2 grep -r token /etc
refused worker2 cat /home/ludorl82/notes.txt
refused 'bad host;x' uptime
refused worker2

printf '\n\033[1m== the remote line is quoted word by word\033[0m\n'
: > "$ROOT/calls"; "$L" worker2 journalctl -u 'nix daemon' >/dev/null
case $(cat "$ROOT/calls") in *'journalctl -u nix\ daemon'*) ok "argument with a space stays one word";; *) bad "quoting: $(cat "$ROOT/calls")";; esac

printf '\n%d passed, %d failed\n' "$pass" "$failed"; [ "$failed" -eq 0 ]
