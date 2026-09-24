#!/usr/bin/env bash
# Tests for ask-local.py's correction loop — how many times it lets the model
# fix its own answer before giving up.
#
# WHY. The ceiling was three. On 2026-09-16 five runs of the suggested-questions
# session needed 1, 2, 3, 3 and then more than 3 attempts: the last one gave up,
# the job went red, and the panel shipped eight questions gpu-01 wrote and none a
# visitor asked. Three was the top of the distribution, not past it.
#
# What is proven here:
#
#   * an answer that lands on the FOURTH attempt now succeeds — that is the
#     run that failed in production;
#   * the ceiling is still a ceiling: exhausting it fails, non-zero and loudly;
#   * a refused attempt leaves NO file behind, because the caller must never
#     publish one — that guarantee is older than this change and must survive
#     it;
#   * the gate itself is untouched. Raising the ceiling buys attempts, never a
#     relaxed check: every attempt here runs the same real check command.
#
# The model is replaced by a fake, so nothing leaves the machine and nothing
# depends on a model's mood. The real `main()` runs.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASK="$SCRIPTS/ask-local.py"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/asklocal-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', wanted '$3'"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: output lacks '$3'";; esac; }

[ -f "$ASK" ] || { echo "ask-local.py missing"; exit 1; }

echo "écris du JSON" > "$ROOT/prompt.md"

# A check that accepts only {"ok": true} — stands in for check-openers, and is
# real: ask-local runs it as a subprocess exactly as it does in production.
cat > "$ROOT/check.py" <<'EOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"unreadable: {e}", file=sys.stderr); sys.exit(1)
if d.get("ok") is True:
    print("check: ok"); sys.exit(0)
print("check: la forme est refusée", file=sys.stderr); sys.exit(1)
EOF

# run <lands-on-attempt> [ASK_ATTEMPTS] -> stdout+stderr, sets $rc
run() {
  local lands="$1" cap="${2:-}"
  rm -f "$ROOT/out.json"
  # `env` and not a bare assignment prefix: bash decides what is an assignment
  # BEFORE expanding, so ${cap:+ASK_ATTEMPTS=$cap} would be taken as the
  # command name instead. The first version of this test did exactly that.
  env ASK_LANDS="$lands" ASK_OUT="$ROOT/out.json" ${cap:+ASK_ATTEMPTS="$cap"} \
      python3 - "$ASK" "$ROOT" <<'PY' 2>&1
import importlib.util, os, sys
mod_path, root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ask_local", mod_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

lands = int(os.environ["ASK_LANDS"])
calls = {"n": 0}
def fake_ask(messages):
    calls["n"] += 1
    # every attempt before `lands` returns a shape the check refuses
    return '{"ok": true}' if calls["n"] >= lands else '{"ok": false}'
m.ask = fake_ask   # replaced on the module, before main() reads it

sys.argv = ["ask-local.py", "--prompt", f"{root}/prompt.md",
            "--out", os.environ["ASK_OUT"], "--",
            "python3", f"{root}/check.py", "$OUT"]
rc = m.main()
print(f"CALLS={calls['n']} RC={rc}")
PY
  rc=$?
}

say "the run that failed in production: the answer lands on attempt 4"
out=$(run 4)
has "it succeeds"          "$out" "ok on attempt 4"
has "after four calls"     "$out" "CALLS=4 RC=0"
[ -s "$ROOT/out.json" ] && ok "and leaves the accepted file" || bad "no output file written"

say "the ceiling is still a ceiling"
out=$(run 99)
has "five calls, then it gives up" "$out" "CALLS=5 RC=1"
has "and says why each time"       "$out" "attempt 5 refused"
[ -e "$ROOT/out.json" ] && bad "a refused attempt was left on disk" \
  || ok "a refused attempt leaves nothing behind"

say "first-try answers still cost exactly one call"
out=$(run 1)
has "no wasted correction" "$out" "CALLS=1 RC=0"

say "the ceiling is overridable, and honoured"
out=$(run 99 2)
has "stops at two"    "$out" "CALLS=2 RC=1"
out=$(run 7 8)
has "and allows more" "$out" "CALLS=7 RC=0"

say "the default is 5, not 3 — the whole point of the change"
grep -q 'ASK_ATTEMPTS", "5"' "$ASK" && ok "default ceiling is 5" || bad "default is not 5"
# and the gate is untouched: the check command still decides, every time
out=$(run 3)
has "every attempt runs the real check" "$out" "ok on attempt 3"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
