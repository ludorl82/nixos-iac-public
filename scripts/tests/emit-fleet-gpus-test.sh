#!/usr/bin/env bash
# Tests for emit-fleet.py's GPU-model join — the gate that ended "which card"
# being free prose.
#
# WHAT IT IS FOR. On 2026-09-14 a second RTX 3050 went into gaming-01. Nothing
# broke and nothing turned red: the model lived in fleet.json's `spec` string,
# `check_gpu` only compares a true/false, and `check_declared` only compares
# device NAMES. The drawing was quietly wrong for two days.
#
# WHAT IS PROVEN HERE, and why each case exists rather than being assumed:
#
#   * a card declared in nixos-iac but missing from fleet.json REFUSES the
#     emit — that is the 2026-09-14 failure, replayed;
#   * PCI slots are per-machine. gaming-01 and gpu-01 both have a card at 65:00.0,
#     and the first real run of this join credited arcade1 with one of gpu-01's
#     3060s. The join is scoped by `hostedBy`, and case 4 is the regression
#     test for the day somebody removes that scoping;
#   * `spec` is RENDERED, never copied, so the string cannot drift from the
#     field it describes;
#   * a device with no cards keeps the `spec` a human wrote — "48 ports, sans
#     ventilateur" has no other source and must survive.
#
# The real emit-fleet.py runs against a fake fleet on disk. Nothing is stubbed
# and nothing leaves the machine: the whole point is that this gate needs no
# network, no nix, and no live host.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMIT="$SCRIPTS/emit-fleet.py"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/emitgpu-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: output lacks '$3'";; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: output still has '$3'";; *) ok "$1";; esac; }

[ -f "$EMIT" ] || { echo "emit-fleet.py missing"; exit 1; }

REPO="$ROOT/repo"; SRC="$ROOT/src"
mkdir -p "$REPO/hosts" "$REPO/scripts" "$SRC"

cat > "$REPO/scripts/host-map.env" <<'EOF'
HOST_MAP=(
  "bigbox:gpu-01"
  "gamebox:gaming-01"
)
FLEET_ALIAS_EXTRA=(
  "guest1:guest1"
  "borrower:vm-03"
)
EOF

# check_racked reads this; no racked classes in the fake fleet, so it only has
# to exist.
echo "rien de racké ici" > "$SRC/physical-layout.md"

host() { mkdir -p "$REPO/hosts/$1"; }
domain() { # domain <host> <bus>...
  local h="$1"; shift
  { echo "<domain>"
    for bus in "$@"; do
      echo "  <hostdev mode='subsystem' type='pci' managed='yes'><source>"
      echo "    <address domain='0x0000' bus='0x$bus' slot='0x00' function='0x0'/>"
      echo "  </source></hostdev>"
      echo "  <hostdev mode='subsystem' type='pci' managed='yes'><source>"
      echo "    <address domain='0x0000' bus='0x$bus' slot='0x00' function='0x1'/>"
      echo "  </source></hostdev>"
    done
    echo "</domain>"; } > "$REPO/hosts/$h/libvirt-domain.xml"
}

host bigbox; host gamebox; host guest1; host borrower

# bigbox: three cards it drives itself, one of them at 65:00.0 — the same slot
# gamebox uses. That collision is the point.
cat > "$REPO/hosts/bigbox/configuration.nix" <<'EOF'
{ ... }:
{
  labo.gpus = [
    { slot = "17:00.0"; id = "10de:2503"; audioId = "10de:228e"; model = "RTX 3060"; die = "GA106"; vram = "12 Go"; }
    { slot = "65:00.0"; id = "10de:2503"; audioId = "10de:228e"; model = "RTX 3060"; die = "GA106"; vram = "12 Go"; }
    { slot = "b4:00.0"; id = "10de:2503"; audioId = "10de:228e"; model = "RTX 3060"; die = "GA106"; vram = "12 Go"; }
  ];
}
EOF

cat > "$REPO/hosts/gamebox/configuration.nix" <<'EOF'
{ ... }:
{
  labo.gpus = [
    { slot = "65:00.0"; id = "10de:2507"; audioId = "10de:228e"; model = "RTX 3050"; die = "GA106"; passthrough = true; }
    { slot = "b4:00.0"; id = "10de:2584"; audioId = "10de:2291"; model = "RTX 3050 6GB"; die = "GA107"; passthrough = true; }
  ];
  boot.kernelParams = [ "vfio-pci.ids=10de:2507,10de:228e,10de:2584,10de:2291" ];
}
EOF

echo '{ }' > "$REPO/hosts/guest1/configuration.nix"
echo '{ }' > "$REPO/hosts/borrower/configuration.nix"
domain guest1 65
domain borrower 65 b4

fleet() { # fleet <gpu-01 gpus json> <gaming-01 gpus json> <guest1 gpus json> <vm-03 gpus json>
  cat > "$SRC/fleet.json" <<EOF
{
  "fleetVersion": 1,
  "devices": [
    {"name":"gpu-01","class":"server","network":"vlan10","role":"r","iacDeclared":true,"gpu":true,"gpus":$1},
    {"name":"gaming-01","class":"server","network":"vlan10","role":"r","iacDeclared":true,"gpu":true,"gpus":$2},
    {"name":"guest1","class":"vm","network":"vlan10","role":"r","iacDeclared":true,"hostedBy":"gaming-01","gpu":true,"gpus":$3},
    {"name":"vm-03","class":"vm","network":"vlan10","role":"r","iacDeclared":true,"hostedBy":"gaming-01","gpu":true,"gpus":$4},
    {"name":"sw-01","class":"switch","network":"vlan10","role":"r","iacDeclared":false,"spec":"48 ports, sans ventilateur"}
  ]
}
EOF
}

BIG3='[{"model":"RTX 3060","die":"GA106","vram":"12 Go","passthrough":false},{"model":"RTX 3060","die":"GA106","vram":"12 Go","passthrough":false},{"model":"RTX 3060","die":"GA106","vram":"12 Go","passthrough":false}]'
GAME2='[{"model":"RTX 3050","die":"GA106","vram":"","passthrough":true},{"model":"RTX 3050 6GB","die":"GA107","vram":"","passthrough":true}]'
G1='[{"model":"RTX 3050","die":"GA106","vram":"","passthrough":true}]'

run() { python3 "$EMIT" "$SRC/fleet.json" "$ROOT/out.json" "$REPO" 2>&1; }
spec_of() { python3 -c "
import json,sys
print(next((d.get('spec','') for d in json.load(open('$ROOT/out.json'))['devices'] if d['name']==sys.argv[1]), '<absent>'))
" "$1"; }

say "everything agrees: it emits, and spec is rendered"
fleet "$BIG3" "$GAME2" "$G1" "$GAME2"
out=$(run); rc=$?
[ "$rc" = 0 ] && ok "emits" || bad "refused: $out"
has "three identical cards group"  "$(spec_of gpu-01)"    "3x RTX 3060 (GA106, 12 Go)"
has "passthrough shows as vfio"    "$(spec_of gaming-01)" "RTX 3050 (GA106, vfio)"
has "and lists both game cards"    "$(spec_of gaming-01)" "RTX 3050 6GB (GA107, vfio)"

say "a device with no cards keeps the spec a human wrote"
has "switch spec survives" "$(spec_of sw-01)" "48 ports, sans ventilateur"

say "THE 2026-09-14 FAILURE: a card in nixos-iac, absent from fleet.json"
fleet "$BIG3" "$G1" "$G1" "$GAME2"
out=$(run); rc=$?
[ "$rc" = 0 ] && bad "emitted despite a missing card" || ok "refuses"
has "names the device"     "$out" "gaming-01:"
has "says what it expects" "$out" "RTX 3050 6GB (GA107, vfio)"
has "and what it found"    "$out" "the two inventories have diverged"

say "SLOT COLLISION: a guest must not inherit the other host's card"
# guest1 claims 65:00.0. bigbox ALSO has a card at 65:00.0. guest1 is hosted by
# gaming-01, so it must be credited with gaming-01's 65:00.0 card and no other.
fleet "$BIG3" "$GAME2" "$G1" "$GAME2"
out=$(run); rc=$?
[ "$rc" = 0 ] && ok "guest1 credited with exactly its host's card" || bad "refused: $out"
hasnt "guest1 did not inherit a 3060" "$(spec_of guest1)" "RTX 3060"
has   "guest1 has the 3050"           "$(spec_of guest1)" "RTX 3050 (GA106, vfio)"

say "a borrower claiming two slots gets both, and only from its host"
has "vm-03 has the first"  "$(spec_of vm-03)" "RTX 3050 (GA106, vfio)"
has "vm-03 has the second" "$(spec_of vm-03)" "RTX 3050 6GB (GA107, vfio)"
hasnt "and no 3060"        "$(spec_of vm-03)" "RTX 3060"

say "a missing gpus field is refused, not treated as 'no cards'"
python3 - "$SRC/fleet.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for x in d["devices"]:
    if x["name"] == "gpu-01": x.pop("gpus")
json.dump(d, open(p,"w"))
PY
out=$(run); rc=$?
[ "$rc" = 0 ] && bad "emitted with no gpus field" || ok "refuses"
has "and says so plainly" "$out" 'has no "gpus" field'

say "passthrough itself is compared, not just the model"
fleet "$BIG3" '[{"model":"RTX 3050","die":"GA106","vram":"","passthrough":false},{"model":"RTX 3050 6GB","die":"GA107","vram":"","passthrough":true}]' "$G1" "$GAME2"
out=$(run); rc=$?
[ "$rc" = 0 ] && bad "a flipped passthrough flag slipped through" || ok "refuses"
has "names gaming-01" "$out" "gaming-01:"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
