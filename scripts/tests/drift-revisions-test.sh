#!/usr/bin/env bash
# Tests for drift-revisions.py — the revision half of the nightly drift check.
#
# What has to be true, and why each one is here rather than assumed:
#
#   * a canary on the canary branch is OK. The loop this replaces compared
#     every host to cp-1, so vm-01/vm-02 read as STALE from every Sunday
#     bump until the promotion — by design, weekly. When the promotion
#     livelocked in September 2026 it was three days straight, with
#     labodeludo.dev/architecture publicly showing "dérive détectée".
#   * a NON-canary on the canary branch is still STALE. The exception is a
#     property of the host, not of the revision; otherwise it would excuse the
#     whole fleet the moment a canary exists.
#   * a canary on MASTER is OK too — that is where it sits between bumps, and
#     it is also where it lands when the judge resets the branch.
#   * an on-demand host that is off does not fail, and an on-demand host that
#     ANSWERS while stale does. That pair is the whole reason vm-03 can be
#     in the list again: it was dropped because "off" failed the job.
#   * an always-on host that is silent still fails. The fix must not buy quiet
#     by making the check blind.
#   * the host list comes from hosts/, so nothing is forgotten by omission.
#
# Nothing leaves the machine: the fleet is a fixture of configuration.nix
# files and the prober is injected.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../drift-revisions.py"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/driftrev-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0
say() { printf '  %-58s %s\n' "$1" "$2"; }

# a fixture fleet: two canaries, one on-demand node, three ordinary hosts
mkdir -p "$ROOT/repo/hosts"/{vm-01,vm-02,vm-03,gpu-01,cloud-01,arcade1}
for h in vm-01 vm-02; do
  printf '{\n  imports = [ ];\n  labo.canary = true;\n}\n' > "$ROOT/repo/hosts/$h/configuration.nix"
done
for h in vm-03 arcade1; do
  printf '{\n  imports = [ ];\n  labo.onDemand = true;\n}\n' > "$ROOT/repo/hosts/$h/configuration.nix"
done
for h in gpu-01 cloud-01; do
  printf '{\n  imports = [ ];\n}\n' > "$ROOT/repo/hosts/$h/configuration.nix"
done

# run <name> <python answers dict> <cp-1> <canary> <expected rc> <grep>
run() {
  local name=$1 answers=$2 cp-1=$3 canary=$4 want_rc=$5 want=$6
  local out rc
  out=$(python3 - "$MOD" "$ROOT/repo" "$cp-1" "$canary" <<EOF
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dr", sys.argv[1])
dr = importlib.util.module_from_spec(spec); spec.loader.exec_module(dr)
answers = $answers
lines, failures = dr.check(sys.argv[2], sys.argv[3],
                           sys.argv[4] or None,
                           prober=lambda h, k: (answers.get(h, ""), "no answer"))
print("\n".join(lines))
sys.exit(1 if failures else 0)
EOF
)
  rc=$?
  if [ "$rc" = "$want_rc" ] && grep -q "$want" <<<"$out"; then
    say "$name" ok; pass=$((pass+1))
  else
    say "$name" FAIL; printf '        rc=%s (attendu %s)\n        %s\n' "$rc" "$want_rc" "$(tr '\n' ' ' <<<"$out")"
    failed=$((failed+1))
  fi
}

M=1111111111111111111111111111111111111111
C=2222222222222222222222222222222222222222
X=3333333333333333333333333333333333333333

echo "drift-revisions.py"

# everybody on cp-1, no canary in flight
run "parc entier sur cp-1 -> vert" \
  "{'vm-01':'$M','vm-02':'$M','vm-03':'$M','gpu-01':'$M','cloud-01':'$M','arcade1':'$M'}" \
  "$M" "" 0 "gpu-01: ok"

# THE REGRESSION: canaries on the canary branch while it is in flight
run "canaris sur la branche canary -> vert" \
  "{'vm-01':'$C','vm-02':'$C','vm-03':'$M','gpu-01':'$M','cloud-01':'$M','arcade1':'$M'}" \
  "$M" "$C" 0 "vm-01: ok (canary)"

# the exception belongs to the host, not to the revision
run "hote ordinaire sur la branche canary -> STALE" \
  "{'vm-01':'$C','vm-02':'$C','vm-03':'$M','gpu-01':'$C','cloud-01':'$M','arcade1':'$M'}" \
  "$M" "$C" 1 "gpu-01: STALE"

# between bumps, and after a reset, a canary sits on cp-1
run "canari sur cp-1 pendant qu'un canari est en vol -> vert" \
  "{'vm-01':'$M','vm-02':'$M','vm-03':'$M','gpu-01':'$M','cloud-01':'$M','arcade1':'$M'}" \
  "$M" "$C" 0 "vm-01: ok"

# a canary on neither is genuinely stale
run "canari sur une troisieme revision -> STALE" \
  "{'vm-01':'$X','vm-02':'$M','vm-03':'$M','gpu-01':'$M','cloud-01':'$M','arcade1':'$M'}" \
  "$M" "$C" 1 "vm-01: STALE"

# vm-03 asleep: the whole reason it could not be in the list before
run "hote a la demande eteint -> pas un echec" \
  "{'vm-01':'$M','vm-02':'$M','gpu-01':'$M','cloud-01':'$M'}" \
  "$M" "" 0 "vm-03: off"

# ...but awake and stale is drift like any other
run "hote a la demande reveille et perime -> STALE" \
  "{'vm-01':'$M','vm-02':'$M','vm-03':'$X','gpu-01':'$M','cloud-01':'$M','arcade1':'$M'}" \
  "$M" "" 1 "vm-03: STALE"

# silence from a host that should be up is still a failure
run "hote toujours-allume muet -> echec" \
  "{'vm-01':'$M','vm-02':'$M','vm-03':'$M','cloud-01':'$M','arcade1':'$M'}" \
  "$M" "" 1 "gpu-01: unverifiable"

# the list is derived, not typed out
run "la liste vient de hosts/ (6 hotes)" \
  "{'vm-01':'$M','vm-02':'$M','vm-03':'$M','gpu-01':'$M','cloud-01':'$M','arcade1':'$M'}" \
  "$M" "" 0 "arcade1: ok"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
