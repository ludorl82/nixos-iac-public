# vm-move <vm> <host> — move a running VM from THIS host to another vmHost,
# live, disk included. See modules/vm-host.nix for the why; this is the how.
#
#   ssh bob sudo vm-move coquille stella
#   ssh bob sudo vm-move --detach coquille stella   # start it and return
#
# Runs as root on the SOURCE host. The work itself runs in a transient systemd
# unit, so it survives the SSH session that started it — which matters most
# when the VM being moved is coquille, the machine that SSH session comes from.
# The caller only follows the journal; if it is cut off, the move goes on:
#   journalctl -u 'vm-move-*' -o cat
#
# Fixed inputs come from the environment (set by the nix wrapper, overridden
# by scripts/tests/vm-move-test.sh):
#   VM_MOVE_PEERS          file of "name address" lines, the other vmHosts
#   VM_MOVE_KEY            this host's private key for vmmove@<peer>
#   VM_MOVE_HEADROOM_KIB   RAM the target must keep free beyond the VM's own
#   VM_MOVE_IMAGES         where disks live (default /var/lib/libvirt/images)

detach=
if [ "${1:-}" = --detach ]; then detach=1; shift; fi
vm="${1:-}"; target="${2:-}"
IMAGES="${VM_MOVE_IMAGES:-/var/lib/libvirt/images}"

log() { echo "vm-move: $*"; }
die() { echo "vm-move: FAILED: $*" >&2; exit 1; }

[ -n "$vm" ] && [ -n "$target" ] || die "usage: vm-move <vm> <host>"
case "$vm" in *[!A-Za-z0-9_-]*) die "bad vm name: $vm" ;; esac
addr=$(awk -v h="$target" '$1 == h { print $2 }' "$VM_MOVE_PEERS")
[ -n "$addr" ] || die "$target is not a vmHost peer of this host ($(awk '{print $1}' "$VM_MOVE_PEERS" | tr '\n' ' '))"

# --- front half: hand off to systemd and follow ----------------------------
if [ -z "${VM_MOVE_DETACHED:-}" ]; then
  [ "$(id -u)" = 0 ] || die "run as root (sudo vm-move ...)"
  unit="vm-move-$vm-$(date +%s)"
  # --detach: start the move and return at once (Home Assistant, through the
  # jumphost's power-ctl, cannot hold a call open for a 10-minute disk copy).
  if [ -n "$detach" ]; then
    systemd-run --unit "$unit" --collect --quiet --setenv VM_MOVE_DETACHED=1 \
      "$(readlink -f "$0")" "$vm" "$target"
    log "started $unit"
    exit 0
  fi
  log "running as $unit; if this session drops, follow with: journalctl -u $unit -o cat"
  journalctl -f -n 0 -o cat -u "$unit" &
  follower=$!
  rc=0
  systemd-run --unit "$unit" --wait --collect --quiet \
    --setenv VM_MOVE_DETACHED=1 "$(readlink -f "$0")" "$vm" "$target" || rc=$?
  sleep 1
  kill "$follower" 2>/dev/null || true
  exit "$rc"
fi

# --- back half: the move itself --------------------------------------------
V=(virsh -c qemu:///system)
R="qemu+ssh://vmmove@$addr/system?keyfile=$VM_MOVE_KEY"
RV=(virsh -c "$R")
SSH=(ssh -i "$VM_MOVE_KEY" -o BatchMode=yes -o ConnectTimeout=8 "vmmove@$addr")

[ "$("${V[@]}" domstate "$vm" 2>/dev/null)" = running ] || die "$vm is not running on this host"
xml=$("${V[@]}" dumpxml "$vm")

# A passed-through PCI device cannot follow the guest: libvirt would refuse
# anyway, but only after the disk copy.
if grep -q '<hostdev' <<<"$xml"; then
  die "$vm has a <hostdev> (passed-through device); it cannot move live"
fi
# host-passthrough without migratable='on' hands the guest invtsc, and
# libvirt then refuses the move — but only after the disk volume exists.
if grep -q "<cpu mode=.host-passthrough.[^>]*migratable=.off" <<<"$xml"; then
  die "$vm uses host-passthrough with migratable='off' (invtsc); set migratable='on' and cold-restart it"
fi
if "${RV[@]}" dominfo "$vm" >/dev/null 2>&1; then
  die "$vm is already defined on $target; one definition per fleet is the lock"
fi

# RAM: the target keeps VM_MOVE_HEADROOM_KIB free beyond the guest. stella
# cannot take coquille while both arcades play.
need=$("${V[@]}" dominfo "$vm" | awk '/^Max memory:/ { print $3 }')
avail=$("${SSH[@]}" cat /proc/meminfo | awk '/^MemAvailable:/ { print $2 }')
[ -n "$need" ] && [ -n "$avail" ] || die "could not read memory (vm: '$need' KiB, $target: '$avail' KiB)"
if [ "$avail" -lt $((need + VM_MOVE_HEADROOM_KIB)) ]; then
  die "$target has $((avail / 1048576)) GiB available; $vm needs $((need / 1048576)) GiB + $((VM_MOVE_HEADROOM_KIB / 1048576)) GiB headroom"
fi

# Volumes this run creates on the target. If the run ends before the
# migration has succeeded, they are empty and in the way of the next try
# ("already exists"), so they go. Seen on the first real run (2026-10-08):
# a missing `sed` stopped the script right after the create.
created=()
migrated=
cleanup() {
  [ -z "$migrated" ] || return 0
  for v in "${created[@]}"; do
    if "${RV[@]}" vol-delete --pool images "$v" >/dev/null 2>&1; then
      log "removed the empty $v from $target"
    else
      log "warning: could not remove $v from $target (vol-delete it by hand)"
    fi
  done
}
trap cleanup EXIT

# Disks: pre-create each one, same capacity, in the target's images pool.
# A file already there is a stale copy from an earlier move or a rebuild —
# refuse rather than guess which one is real.
disks=()
while read -r type device tgt src; do
  [ "$type" = file ] && [ "$device" = disk ] || continue
  [ "$(dirname "$src")" = "$IMAGES" ] || die "disk $tgt ($src) is outside $IMAGES"
  name=$(basename "$src")
  if "${RV[@]}" vol-info --pool images "$name" >/dev/null 2>&1; then
    die "$name already exists on $target; move it aside first"
  fi
  cap=$("${V[@]}" domblkinfo "$vm" "$tgt" | awk '/^Capacity:/ { print $2 }')
  fmt=raw; case "$name" in *.qcow2) fmt=qcow2 ;; esac
  log "creating $name on $target ($((cap / 1073741824)) GiB, $fmt)"
  "${RV[@]}" vol-create-as images "$name" "${cap}b" --format "$fmt" >/dev/null \
    || die "could not create $name on $target"
  created+=("$name")
  disks+=("$src")
done < <("${V[@]}" domblklist "$vm" --details | tail -n +3)
[ "${#disks[@]}" -gt 0 ] || die "$vm has no file-backed disk under $IMAGES"

# UEFI vars: QEMU migrates the flash contents in memory, but the FILE on the
# target would be a fresh template — the next cold boot would lose the boot
# entries. Copy it first; vm-move-receive refuses a domain the target defines.
nvram=$(sed -n 's|.*<nvram[^>]*>\([^<]*\)</nvram>.*|\1|p' <<<"$xml")
if [ -n "$nvram" ]; then
  log "copying UEFI vars"
  "${SSH[@]}" sudo /run/current-system/sw/bin/vm-move-receive nvram "$vm" < "$nvram" \
    || die "could not copy $nvram to $target"
fi

log "migrating $vm to $target ($addr), live, disks included"
"${V[@]}" migrate --live --persistent --undefinesource --copy-storage-all \
  --auto-converge --verbose "$vm" "$R" --migrateuri "tcp://$addr" \
  || die "virsh migrate failed; $vm should still be running here (check: virsh list)"
migrated=1

[ "$("${RV[@]}" domstate "$vm" 2>/dev/null)" = running ] || die "$vm is not running on $target after the migration"
if "${V[@]}" dominfo "$vm" >/dev/null 2>&1; then
  die "$vm is still defined here after the migration"
fi
# Autostart belongs to the host that defines the VM (the flag does not travel).
"${RV[@]}" autostart "$vm" >/dev/null || log "warning: could not set autostart on $target"

# The disk left behind is a stale copy now. Keep ONE generation aside, so a
# move back can create the volume again.
for src in "${disks[@]}"; do
  mv -f "$src" "$src.vm-move-old"
done
"${V[@]}" pool-refresh images >/dev/null 2>&1 || true

log "OK: $vm runs on $target"
