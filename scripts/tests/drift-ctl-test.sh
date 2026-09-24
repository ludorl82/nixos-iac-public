#!/usr/bin/env bash
# Tests for the drift-ctl forced command in modules/drift-check.nix.
#
# WHY THIS EXISTS, stated plainly: the first version of that dispatcher broke
# the nightly drift check, and the commit message asserted it had not. The
# Cronicle event calls `ssh … driftcheck@$h.lab.example true`. That word was inert
# while the forced command ignored SSH_ORIGINAL_COMMAND; giving the command
# meaning gave the word meaning, and every host answered "denied". Nine hosts
# would have read "unverifiable" at 04:31 and Kuma 42 would have gone red.
#
# It was caught by probing a live host after deploying — which is luck dressed
# up as diligence, because the probe was aimed at the new verb, not the old
# one. This suite is the version that does not need luck.
#
# THE SCRIPT IS LIFTED FROM THE MODULE, never retyped. A copy of a dispatcher
# is a second dispatcher, and it is always the copy that still passes after the
# real one changes. The only edits made here are the two things nix owns: the
# interpolated PATH, and its '' escaping.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPTS/../modules/drift-check.nix"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/driftctl-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', wanted '$3'"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: output lacks '$3'";; esac; }

[ -f "$MODULE" ] || { echo "modules/drift-check.nix missing"; exit 1; }

# --- lift the dispatcher out of the nix file -------------------------------
python3 - "$MODULE" "$ROOT/drift-ctl" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'writeShellScript "drift-ctl" \'\'\n(.*?)\n  \'\';', src, re.S)
if not m:
    sys.exit("could not lift drift-ctl out of the module")
body = m.group(1)
# nix owns exactly two things in here: the interpolated PATH line, and ''$
# escaping. Everything else must run verbatim or this tests a fiction.
body = re.sub(r'^\s*export PATH=.*$', '', body, count=1, flags=re.M)
body = body.replace("''${", "${")
open(sys.argv[2], "w").write("#!/usr/bin/env bash\n" + body + "\n")
print("lifted", len(body.splitlines()), "lines")
PY
[ -s "$ROOT/drift-ctl" ] || { echo "lift failed"; exit 1; }
chmod +x "$ROOT/drift-ctl"

# --- stubs for the two commands it shells out to ---------------------------
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/nixos-version" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--configuration-revision" ] || { echo "unexpected args: $*" >&2; exit 9; }
echo "9961b86f1e3b0803efbe8b3ce207782e19be18c7"
EOF
cat > "$ROOT/bin/lspci" <<'EOF'
#!/usr/bin/env bash
# Real output captured from gpu-01 on 2026-09-16: three display controllers and
# three audio functions, one of them a different part from the other two.
cat <<'OUT'
17:00.0 0300: 10de:2503 (rev a1)
17:00.1 0403: 10de:228e (rev a1)
65:00.0 0300: 10de:2503 (rev a1)
65:00.1 0403: 10de:228e (rev a1)
b4:00.0 0300: 10de:2504 (rev a1)
b4:00.1 0403: 10de:228e (rev a1)
OUT
EOF
chmod +x "$ROOT/bin/nixos-version" "$ROOT/bin/lspci"

ctl() { # ctl <SSH_ORIGINAL_COMMAND>
  PATH="$ROOT/bin:$PATH" SSH_ORIGINAL_COMMAND="$1" "$ROOT/drift-ctl" 2>"$ROOT/err"
}

REV="9961b86f1e3b0803efbe8b3ce207782e19be18c7"

say "THE REGRESSION: the Cronicle drift check sends 'true'"
out=$(ctl "true"); rc=$?
is "exits 0"            "$rc"  "0"
is "prints the revision" "$out" "$REV"

say "and the other two ways of asking for the same thing"
out=$(ctl ""); is "empty command"      "$out" "$REV"
out=$(ctl "revision"); is "explicit verb" "$out" "$REV"

say "the revision answer is exactly one line and nothing else"
is "one line" "$(ctl 'true' | wc -l)" "1"
is "no stderr" "$(ctl 'true' >/dev/null; wc -c < "$ROOT/err")" "0"

say "gpus returns one JSON object per display controller"
out=$(ctl "gpus")
is "three cards, not six" "$(wc -l <<<"$out")" "3"
has "the first"  "$out" '{"slot": "17:00.0", "id": "10de:2503"}'
has "the third"  "$out" '{"slot": "b4:00.0", "id": "10de:2504"}'
case "$out" in *228e*) bad "audio function leaked in";; *) ok "drops the audio functions";; esac
python3 -c "
import json,sys
for l in sys.stdin:
    if l.strip(): json.loads(l)
" <<<"$out" && ok "every line parses as JSON" || bad "output is not JSON"

say "anything else is refused, loudly, and on stderr"
out=$(ctl "rm -rf /"); rc=$?
is   "non-zero"        "$rc" "1"
is   "nothing on stdout" "$out" ""
has  "says what it knows" "$(cat "$ROOT/err")" "drift-ctl knows 'revision' and 'gpus'"

say "extra words after a known verb do not change it"
out=$(ctl "revision --and-something-else"); is "still the revision" "$out" "$REV"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
