#!/usr/bin/env bash
# Tests for scripts/vm-move.sh (modules/vm-host.nix).
#
# vm-move is the script that moves coquille — the machine running the session
# that typed it. A refusal that comes too late (after a 100 GB disk copy) or
# not at all (a second definition on the target, a stale disk overwritten) is
# the failure that matters, so that is what this checks: every refusal fires
# BEFORE `virsh migrate`, and the happy path issues the migrate it should.
#
# virsh and ssh are fakes driven by files under $ROOT; nothing here touches
# libvirt. The back half runs directly (VM_MOVE_DETACHED=1); the systemd-run
# front half is a few lines, exercised on the real hosts.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vmmove-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: output lacks '$3' — got: $2";; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: output has '$3'";; *) ok "$1";; esac; }

mkdir -p "$ROOT/bin" "$ROOT/images" "$ROOT/tools"

# The script runs with ONLY the commands of its runtimeInputs in the module
# — the first real move (2026-10-08) died on `sed: command not found` because
# this suite ran with the console's full PATH. The package list is read from
# modules/vm-host.nix; each package maps to the commands it provides that a
# script could use. libvirt and openssh are the fakes below.
MODULE="$SCRIPTS/../modules/vm-host.nix"
inputs=$(sed -n 's/.*runtimeInputs = with pkgs; \[\(.*\)\];.*/\1/p' "$MODULE")
[ -n "$inputs" ] || { echo "could not read runtimeInputs from $MODULE"; exit 1; }
# bash itself: writeShellApplication's interpreter, and the fakes' shebang.
ln -s "$(command -v bash)" "$ROOT/tools/bash"
for pkg in $inputs; do
  case "$pkg" in
    coreutils) cmds="cat head tail tr cut dirname basename readlink date id mv rm cp touch mkdir mktemp sleep env sort uniq wc" ;;
    gnugrep)   cmds="grep" ;;
    gnused)    cmds="sed" ;;
    gawk)      cmds="awk gawk" ;;
    systemd)   cmds="systemd-run journalctl systemctl" ;;
    libvirt|openssh|util-linux) cmds="" ;;
    *) echo "unknown runtime input '$pkg': map it in this test"; exit 1 ;;
  esac
  for c in $cmds; do
    p=$(command -v "$c") && ln -sf "$p" "$ROOT/tools/$c"
  done
done
printf 'luna 192.0.2.140\n' > "$ROOT/peers"

# Fake virsh. Local state: $ROOT/local/<vm>.xml (defined) + .running.
# Remote state (any -c qemu+ssh://...): $ROOT/remote/... Every call is logged.
cat > "$ROOT/bin/virsh" <<'EOF'
#!/usr/bin/env bash
echo "virsh $*" >> "$ROOT/calls"
side=local
if [ "$1" = -c ]; then case "$2" in qemu+ssh://*) side=remote ;; esac; shift 2; fi
D="$ROOT/$side"; cmd="$1"; shift
case "$cmd" in
  domstate) [ -f "$D/$1.xml" ] || exit 1; [ -f "$D/$1.running" ] && echo running || echo "shut off" ;;
  dominfo)  [ -f "$D/$1.xml" ] || exit 1; echo "Max memory:     16777216 KiB" ;;
  dumpxml)  cat "$D/$1.xml" ;;
  domblklist) printf ' Type   Device   Target   Source\n----\n file   disk     vda      %s\n file   cdrom    hda      -\n' "$ROOT/images/$1.qcow2" ;;
  domblkinfo) echo "Capacity:       107374182400" ;;
  vol-info) [ -f "$D/vol-$3" ] ;;
  vol-create-as) touch "$D/vol-$2" ;;
  vol-delete) rm "$D/vol-$3" ;;
  migrate)  [ -f "$ROOT/migrate-fails" ] && exit 1
            vm="${*: -4:1}"; mv "$ROOT/local/$vm.xml" "$ROOT/remote/$vm.xml"
            rm -f "$ROOT/local/$vm.running"; touch "$ROOT/remote/$vm.running" ;;
  autostart|pool-refresh) ;;
  *) echo "fake virsh: unhandled $cmd" >&2; exit 2 ;;
esac
EOF
cat > "$ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$ROOT/calls"
case "$*" in
  *"cat /proc/meminfo"*) echo "MemAvailable:   $(cat "$ROOT/remote-avail") kB" ;;
  *vm-move-receive*) cat > "$ROOT/remote/nvram" ;;
esac
EOF
chmod +x "$ROOT/bin/"*

XML="<domain><name>coquille</name><os><nvram>$ROOT/vars.fd</nvram></os><devices></devices></domain>"
echo vars > "$ROOT/vars.fd"

reset() {
  rm -rf "$ROOT/local" "$ROOT/remote" "$ROOT/calls" "$ROOT/migrate-fails" "$ROOT/images/"*
  mkdir -p "$ROOT/local" "$ROOT/remote"
  echo "$XML" > "$ROOT/local/coquille.xml"; touch "$ROOT/local/coquille.running"
  touch "$ROOT/images/coquille.qcow2"; echo vars > "$ROOT/vars.fd"
  echo $((40 * 1048576)) > "$ROOT/remote-avail"
}
run() {
  ROOT="$ROOT" PATH="$ROOT/bin:$ROOT/tools" VM_MOVE_DETACHED=1 VM_MOVE_PEERS="$ROOT/peers" \
    VM_MOVE_KEY=/nonexistent VM_MOVE_HEADROOM_KIB=$((4 * 1048576)) VM_MOVE_IMAGES="$ROOT/images" \
    "$BASH" -euo pipefail "$SCRIPTS/vm-move.sh" "$@" 2>&1
}
migrated() { grep -q '^virsh .* migrate ' "$ROOT/calls" 2>/dev/null; }

say "happy path"
reset; out=$(run coquille luna); rc=$?
[ $rc = 0 ] && ok "exit 0" || bad "exit $rc: $out"
has "reports success" "$out" "OK: coquille runs on luna"
grep -q -- '--live --persistent --undefinesource --copy-storage-all' "$ROOT/calls" && ok "migrate flags" || bad "migrate flags"
grep -q -- '--migrateuri tcp://192.0.2.140' "$ROOT/calls" && ok "data over the peer's VLAN10 address" || bad "migrateuri"
[ -f "$ROOT/remote/vol-coquille.qcow2" ] && ok "disk pre-created on target" || bad "disk not pre-created"
[ "$(cat "$ROOT/remote/nvram" 2>/dev/null)" = vars ] && ok "UEFI vars copied" || bad "UEFI vars not copied"
[ -f "$ROOT/images/coquille.qcow2.vm-move-old" ] && [ ! -f "$ROOT/images/coquille.qcow2" ] \
  && ok "stale source disk set aside" || bad "source disk not set aside"
grep -q 'virsh -c qemu+ssh.* autostart coquille' "$ROOT/calls" && ok "autostart set on target" || bad "no autostart"

say "refusals, all before any migrate"
reset; out=$(run coquille nowhere)
has "unknown host" "$out" "not a vmHost peer"; migrated && bad "migrated anyway" || ok "no migrate"

reset; out=$(run 'coq;rm' luna)
has "bad name" "$out" "bad vm name"

reset; rm "$ROOT/local/coquille.running"; out=$(run coquille luna)
has "not running" "$out" "not running on this host"; migrated && bad "migrated anyway" || ok "no migrate"

reset; echo "<domain><devices><hostdev mode='subsystem'/></devices></domain>" > "$ROOT/local/coquille.xml"
out=$(run coquille luna)
has "hostdev" "$out" "<hostdev>"; migrated && bad "migrated anyway" || ok "no migrate"

reset; echo "<domain><cpu mode='host-passthrough' check='none' migratable='off'/><devices></devices></domain>" > "$ROOT/local/coquille.xml"
out=$(run coquille luna)
has "non-migratable CPU" "$out" "migratable='off'"; migrated && bad "migrated anyway" || ok "no migrate"
[ ! -f "$ROOT/remote/vol-coquille.qcow2" ] && ok "no volume created" || bad "volume created before the CPU refusal"

reset; echo "$XML" > "$ROOT/remote/coquille.xml"; out=$(run coquille luna)
has "already defined on target" "$out" "already defined on luna"; migrated && bad "migrated anyway" || ok "no migrate"

reset; echo $((18 * 1048576)) > "$ROOT/remote-avail"; out=$(run coquille luna)
has "not enough RAM (16 + 4 > 18)" "$out" "18 GiB available"; migrated && bad "migrated anyway" || ok "no migrate"

reset; touch "$ROOT/remote/vol-coquille.qcow2"; out=$(run coquille luna)
has "stale disk on target" "$out" "already exists on luna"; migrated && bad "migrated anyway" || ok "no migrate"

say "a failed migrate leaves the source alone"
reset; touch "$ROOT/migrate-fails"; out=$(run coquille luna); rc=$?
[ $rc != 0 ] && ok "non-zero exit" || bad "exit 0 on a failed migrate"
has "says so" "$out" "virsh migrate failed"
[ -f "$ROOT/images/coquille.qcow2" ] && ok "source disk untouched" || bad "source disk moved after a failure"
lacks "no success line" "$out" "OK:"
[ ! -f "$ROOT/remote/vol-coquille.qcow2" ] && ok "empty target volume removed" || bad "empty volume left on target"

say "a refusal after the create removes what it created"
reset; rm "$ROOT/vars.fd"; out=$(run coquille luna); rc=$?
[ $rc != 0 ] && ok "non-zero exit" || bad "exit 0 with an unreadable nvram"
[ ! -f "$ROOT/remote/vol-coquille.qcow2" ] && ok "empty target volume removed" || bad "empty volume left on target"
has "says so" "$out" "removed the empty coquille.qcow2"

say "a successful move keeps the target volume"
reset; out=$(run coquille luna)
[ -f "$ROOT/remote/vol-coquille.qcow2" ] && ok "kept" || bad "target volume deleted after success"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" = 0 ]
