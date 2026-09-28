#!/usr/bin/env bash
# Tests for gpu-discovery.py — the third opinion on the GPU inventory.
#
# The comparison itself is covered by the script's own --selftest, which runs
# on every real invocation. What is proven HERE is the wiring, because the
# wiring holds the decisions no single comparison can see:
#
#   * a host that did not answer is UNVERIFIED and does NOT fail the run. That
#     is the whole reason discovery is not the source: gaming-01's gaming guests
#     are off almost always by design, and a check that paged for them would
#     be muted within a week.
#   * a host that DISAGREES does fail it, with an exit code Cronicle can read.
#   * a host declaring no cards is still probed, so a card put into a machine
#     nobody thought of is caught. That is the case the declaration can never
#     catch on its own.
#   * the awk that turns `lspci -n` into JSON drops the card's audio function
#     and keeps the display one — run here against real output captured from
#     the fleet, so the module's parser is exercised without deploying it.
#
# Nothing leaves the machine: the prober is replaced by a fake, and the lspci
# output is a fixture.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISC="$SCRIPTS/gpu-discovery.py"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gpudisc-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', wanted '$3'"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: output lacks '$3'";; esac; }

[ -f "$DISC" ] || { echo "gpu-discovery.py missing"; exit 1; }

say "the comparison proves itself"
out=$(python3 "$DISC" --selftest 2>&1); rc=$?
is  "selftest exits 0" "$rc" "0"
has "and says so"      "$out" "7/7 passed"

# --- a fake fleet: one host with cards, one with none, one unreachable ------
REPO="$ROOT/repo"
mkdir -p "$REPO/hosts/withcards" "$REPO/hosts/nocards" "$REPO/hosts/asleep" "$REPO/scripts"
cp "$SCRIPTS/emit-fleet.py" "$REPO/scripts/emit-fleet.py"

cat > "$REPO/hosts/withcards/configuration.nix" <<'EOF'
{ ... }:
{
  labo.gpus = [
    { slot = "17:00.0"; id = "10de:2503"; audioId = "10de:228e"; model = "RTX 3060"; die = "GA106"; }
    { slot = "65:00.0"; id = "10de:2503"; audioId = "10de:228e"; model = "RTX 3060"; die = "GA106"; }
  ];
}
EOF
echo '{ }' > "$REPO/hosts/nocards/configuration.nix"
echo '{ }' > "$REPO/hosts/asleep/configuration.nix"

# A passthrough guest: declares nothing, claims a slot in its domain. Its cards
# belong to its host and are verified there.
mkdir -p "$REPO/hosts/guest"
echo '{ }' > "$REPO/hosts/guest/configuration.nix"
cat > "$REPO/hosts/guest/libvirt-domain.xml" <<'XML'
<domain>
  <hostdev mode='subsystem' type='pci' managed='yes'><source>
    <address domain='0x0000' bus='0x65' slot='0x00' function='0x0'/>
  </source></hostdev>
</domain>
XML

# The driver is imported and its prober replaced — never monkeypatched after
# the fact, which is how a fake silently stops being used.
harness() { # harness <python dict literal of host -> (cards, err)>
  python3 - "$REPO" "$DISC" "$1" <<'PY'
import importlib.util, json, sys
repo, disc, answers = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
spec = importlib.util.spec_from_file_location("gd", disc)
gd = importlib.util.module_from_spec(spec); spec.loader.exec_module(gd)

def fake(host, key=None):
    a = answers.get(host)
    if a is None:
        return [], "no route to host"
    return a.get("cards", []), a.get("err", "")

lines, bad, unknown = gd.run(repo, prober=fake)
print("\n".join(lines))
print(f"TOTALS bad={bad} unknown={unknown}")
PY
}

C2='[{"slot":"17:00.0","id":"10de:2503"},{"slot":"65:00.0","id":"10de:2503"}]'

say "everything agrees"
out=$(harness "{\"withcards\": {\"cards\": $C2}, \"nocards\": {\"cards\": []}, \"asleep\": {\"cards\": []}}")
has "the card host agrees"   "$out" "AGREES      withcards: 2 card(s)"
has "the empty host agrees"  "$out" "AGREES      nocards: no card, none declared"
has "nothing failed"         "$out" "TOTALS bad=0 unknown=0"

say "a host that did not answer is UNVERIFIED, and does not fail the run"
out=$(harness "{\"withcards\": {\"cards\": $C2}, \"nocards\": {\"cards\": []}}")
has "asleep is unverified" "$out" "UNVERIFIED  asleep: no route to host"
has "and is not a failure" "$out" "TOTALS bad=0 unknown=1"

say "THE 2026-09-14 FAILURE: a card in the machine that nothing declares"
out=$(harness "{\"withcards\": {\"cards\": [{\"slot\":\"17:00.0\",\"id\":\"10de:2503\"},{\"slot\":\"65:00.0\",\"id\":\"10de:2503\"},{\"slot\":\"b4:00.0\",\"id\":\"10de:2504\"}]}, \"nocards\": {\"cards\": []}, \"asleep\": {\"cards\": []}}")
has "it disagrees"        "$out" "DISAGREES   withcards"
has "and names the card"  "$out" "10de:2504 at b4:00.0 and nothing declares it"
has "and fails"           "$out" "TOTALS bad=1 unknown=0"

say "a card appearing in a host that declares NONE is caught too"
out=$(harness "{\"withcards\": {\"cards\": $C2}, \"nocards\": {\"cards\": [{\"slot\":\"01:00.0\",\"id\":\"10de:1401\"}]}, \"asleep\": {\"cards\": []}}")
has "the empty host disagrees" "$out" "DISAGREES   nocards"
has "and names it"             "$out" "10de:1401 at 01:00.0"

say "a declared card that vanished is caught"
out=$(harness "{\"withcards\": {\"cards\": [{\"slot\":\"17:00.0\",\"id\":\"10de:2503\"}]}, \"nocards\": {\"cards\": []}, \"asleep\": {\"cards\": []}}")
has "missing card reported" "$out" "declared at 65:00.0 (10de:2503) but the host does not see it"

say "the module's awk, against real lspci output from the fleet"
# Captured from gpu-01 on 2026-09-16. Three display controllers, three audio
# functions; a parser that keeps the audio would report six cards.
cat > "$ROOT/lspci.txt" <<'EOF'
17:00.0 0300: 10de:2503 (rev a1)
17:00.1 0403: 10de:228e (rev a1)
65:00.0 0300: 10de:2503 (rev a1)
65:00.1 0403: 10de:228e (rev a1)
b4:00.0 0300: 10de:2504 (rev a1)
b4:00.1 0403: 10de:228e (rev a1)
EOF
# The exact awk program from modules/drift-check.nix, lifted rather than
# retyped: a copy would drift from the thing it claims to test.
prog=$(python3 - "$SCRIPTS/../modules/drift-check.nix" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"lspci -n -d 10de: \| awk '(.*?)'", src, re.S)
print(m.group(1) if m else "", end="")
PY
)
[ -n "$prog" ] && ok "awk program lifted from the module" || bad "could not lift the awk program"
got=$(awk "$prog" < "$ROOT/lspci.txt")
is "three cards, not six" "$(wc -l <<<"$got")" "3"
has "keeps the display function" "$got" '{"slot": "17:00.0", "id": "10de:2503"}'
has "keeps the Lite Hash Rate"   "$got" '{"slot": "b4:00.0", "id": "10de:2504"}'
case "$got" in *228e*) bad "audio function leaked in";; *) ok "drops the audio function";; esac
python3 -c "
import json,sys
for line in sys.stdin:
    line=line.strip()
    if line: json.loads(line)
print('parses as JSON')" <<<"$got" >/dev/null 2>&1 && ok "every line is valid JSON" || bad "output is not JSON"

say "A RUNNING PASSTHROUGH GUEST IS NOT A DIVERGENCE"
# The guest sees its borrowed card at an address qemu invented — 05:00.0 where
# the host calls it 65:00.0. Asking it produced a DISAGREES on the first live
# run of this script, on a night vm-03 happened to be awake. That alarm would
# fire every time a gaming VM is on, and be ignored within the week.
out=$(harness "{\"withcards\": {\"cards\": $C2}, \"nocards\": {\"cards\": []}, \"asleep\": {\"cards\": []}, \"guest\": {\"cards\": [{\"slot\":\"05:00.0\",\"id\":\"10de:2507\"}]}}")
has "the guest is skipped, not judged" "$out" "SKIPPED     guest: passthrough guest"
has "and nothing disagrees"            "$out" "TOTALS bad=0"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
