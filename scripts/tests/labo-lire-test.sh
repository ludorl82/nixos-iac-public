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
allowed pi-02 uptime
allowed gpu-01 nvidia-smi --query-gpu=name,memory.used --format=csv
allowed gpu-01 nvidia-smi
allowed gaming-01 systemctl status k3s
allowed gaming-01 systemctl --failed
allowed console-vm journalctl -u qwen-voice-bridge -n 50 --no-pager
allowed srv-01 cat /proc/mdstat
allowed srv-01 df -h
allowed gpu-01 docker ps
allowed gpu-01 virsh list --all
allowed pi-02 ip route show
allowed pi-02 tail -n 20 /var/log/messages
allowed pi-02 grep -i error /var/log/messages
allowed pi-02 tail -n 80 /home/ludorl82/logs/weekly-updates.log
allowed pi-02 grep -n FAILED /home/ludorl82/logs/weekly-updates.log
allowed gpu-01 zpool status
allowed pi-02 hostname
allowed pi-02 date

printf '\n\033[1m== writes are refused\033[0m\n'
refused gaming-01 systemctl restart k3s
refused gaming-01 systemctl stop comin
refused gpu-01 docker rm -f frigate
refused gpu-01 docker run alpine
refused pi-02 cat /home/ludorl82/logs/../.bash_history
refused pi-02 cat /var/log/../../home/ludorl82/nixos-iac/flake.nix
refused pi-02 cat /home/ludorl82/notes.txt
refused pi-02 cat /home/ludorl82/logs/../.ssh/config
refused gpu-01 virsh destroy arcade1
refused gpu-01 virsh start vm-03
refused gpu-01 nvidia-smi -r
refused gpu-01 nvidia-smi -pl 100
refused pi-02 ip route add 198.18.0.0/15 dev lo
refused pi-02 ip link set eth0 down
refused pi-02 journalctl --vacuum-time=1d
refused pi-02 hostname pwned
refused pi-02 date -s 2020-01-01
refused gpu-01 zpool destroy tank
refused gpu-01 mdadm --stop /dev/md0
refused pi-02 tail -f /var/log/messages
refused pi-02 rm -rf /tmp/x
refused pi-02 sudo cat /etc/shadow
refused pi-02 kp-get Kuma
refused pi-02 bash -c id

printf '\n\033[1m== chaining and secrets are refused\033[0m\n'
refused pi-02 uptime ';' rm -rf /
refused pi-02 'uptime; reboot'
refused pi-02 cat '/proc/$(reboot)'
refused pi-02 cat /etc/passwd '|' sh
refused pi-02 cat /etc/ssh/ssh_host_ed25519_key
refused pi-02 cat /var/lib/qwen-voice/env
refused pi-02 cat /home/ludorl82/.kube/config
refused pi-02 grep -r token /etc
refused pi-02 cat /home/ludorl82/notes.txt
refused 'bad host;x' uptime
refused pi-02

printf '\n\033[1m== the remote line is quoted word by word\033[0m\n'
: > "$ROOT/calls"; "$L" pi-02 journalctl -u 'nix daemon' >/dev/null
case $(cat "$ROOT/calls") in *'journalctl -u nix\ daemon'*) ok "argument with a space stays one word";; *) bad "quoting: $(cat "$ROOT/calls")";; esac

printf '\n%d passed, %d failed\n' "$pass" "$failed"; [ "$failed" -eq 0 ]
