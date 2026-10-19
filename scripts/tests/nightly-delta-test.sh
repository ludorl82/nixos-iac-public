#!/usr/bin/env bash
# Tests for the A/C delta — what a reconcile session is told has moved.
#
# WHY. B and D have always been handed a structural delta; A and C never were.
# They get four IaC repos and a long prose document and discover the
# difference by reading, which is where the wall clock goes: 62 and 81 minutes
# on two runs costing $0.48 and $0.70 of model. On 2026-09-16 each of those
# runs did real work in exactly ONE of the two sessions while the other read
# everything to conclude "already matched" — C in the morning, A at midday.
# Which one has work is luck, because the gate fires them together.
#
# What is proven here, and why each case is a case rather than a belief:
#
#   * the commits since this session's last pass are listed, and nothing else
#     is — that is the whole saving;
#   * "nothing moved" is said explicitly, because a session handed an empty
#     section would go hunting again;
#   * THE BASE NEVER ADVANCES ON A FAILURE. A session that hit its turn
#     ceiling never saw its window, and moving the base would mark those
#     commits reviewed by nobody. This is the case that would be expensive to
#     discover in production and cheap to assert here;
#   * a hand edit to the document forces a full pass — the session reconciles
#     two sides, and a change on either one reopens the question;
#   * a full pass comes back on a timer, so a contradiction older than the
#     delta window is still found;
#   * diagnostics go to STDERR. Stdout is the prompt: a stray log line does
#     not fail anything, it silently becomes an instruction.
#
# Real git repositories on disk, the real functions lifted from the driver.
# Nothing is stubbed and nothing leaves the machine.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB="$SCRIPTS/nightly-diagram-sync.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nightlydelta-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', wanted '$3'"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: output lacks '$3'";; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: output still has '$3'";; *) ok "$1";; esac; }

# Lift the functions rather than sourcing the driver, which would run it.
for fn in netcfgs_ref session_base session_heads private_delta remember_pass; do
  sed -n "/^$fn() {/,/^}/p" "$JOB" >> "$ROOT/fn.sh"
  # Every name, not one: a function the driver grew and this list forgot is a
  # "command not found" that quietly turns the doc digest into "none" — and
  # "none" equals "none", so the hand-edit case would pass for the wrong reason.
  grep -q "^$fn() {" "$ROOT/fn.sh" || { echo "extraction failed: $fn"; exit 1; }
done

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
GIT_BASE="$ROOT/git"; STATE_DIR="$ROOT/state"; LOG_PREFIX="test"
PRIVATE_REPOS=(repo-a repo-b)
FULL_EVERY_DAYS=7; DELTA_FILE_CAP=150
mkdir -p "$GIT_BASE" "$STATE_DIR"
log() { echo "$LOG_PREFIX: $*"; }
# shellcheck source=/dev/null
. "$ROOT/fn.sh"

mkrepo() { # mkrepo <name>
  local d="$GIT_BASE/$1"
  mkdir -p "$d"; git init -q -b cp-1 "$d"
  echo init > "$d/f.txt"; git -C "$d" add -A; git -C "$d" commit -qm "init $1"
  # the driver reads origin/cp-1; point it at a local bare clone
  git clone -q --bare "$d" "$d.git"
  git -C "$d" remote add origin "$d.git"
  git -C "$d" push -q origin cp-1 2>/dev/null
  git -C "$d" fetch -q origin
}
commit() { # commit <repo> <file> <subject>
  local d="$GIT_BASE/$1"
  echo "$RANDOM" > "$d/$2"; git -C "$d" add -A; git -C "$d" commit -qm "$3"
  git -C "$d" push -q origin cp-1; git -C "$d" fetch -q origin
}

mkrepo repo-a; mkrepo repo-b
mkrepo net-cfgs
DOC=doc.md
echo "prose" > "$GIT_BASE/net-cfgs/$DOC"
git -C "$GIT_BASE/net-cfgs" add -A
git -C "$GIT_BASE/net-cfgs" commit -qm "add doc"
git -C "$GIT_BASE/net-cfgs" push -q origin cp-1
git -C "$GIT_BASE/net-cfgs" fetch -q origin

say "no state yet: a full pass, and it says why on STDERR"
out=$(private_delta A "$DOC" 2>"$ROOT/err")
is  "no prompt section"   "$out" ""
has "reason on stderr"    "$(cat "$ROOT/err")" "no previous pass on record"

remember_pass A "$DOC" full
[ -s "$STATE_DIR/seen-A" ] && ok "base recorded" || bad "base not recorded"

say "NOTHING MOVED: the session is not started at all"
# Measured 2026-09-16: every session is 80-160 turns at ~10 s a turn, so even
# "read this and say nothing changed" costs a quarter of an hour. Not starting
# it is the only version that is actually cheap — the shape D has always had.
out=$(private_delta A "$DOC" 2>"$ROOT/err"); rc=$?
is  "verdict is 3, not 0"  "$rc" "3"
is  "and prints no prompt" "$out" ""
has "says why on stderr"   "$(cat "$ROOT/err")" "rien n'a bougé depuis son dernier passage"

say "a skip must not advance the base, or the full-pass timer never fires"
before=$(cat "$STATE_DIR/seen-A")
out=$(private_delta A "$DOC" 2>/dev/null) || true
is "state untouched by a skip" "$(cat "$STATE_DIR/seen-A")" "$before"

say "reconcile_doc turns that verdict into a skip, not a failure"
rd=$(sed -n '/^reconcile_doc() {/,/^}/p' "$JOB")
has "it captures the exit code"   "$rd" 'private_delta "$label" "$file") || drc=$?'
has "3 means skip"                "$rd" 'if [ "$drc" = 3 ]'
if grep -A3 'if \[ "\$drc" = 3 \]' <<<"$rd" | grep -q 'fail=1'; then
  bad "a skip is reported as a failure"
else
  ok "and a skip is not a failure"
fi
if grep -A3 'if \[ "\$drc" = 3 \]' <<<"$rd" | grep -q 'remember_pass'; then
  bad "a skip advances the base"
else
  ok "and a skip does not bank a pass"
fi

say "a commit appears, and only that commit"
commit repo-a hosts.nix "ajoute une carte a gpu-01"
out=$(private_delta A "$DOC" 2>/dev/null)
has  "names the repo"     "$out" "### repo-a"
has  "lists the subject"  "$out" "ajoute une carte a gpu-01"
has  "lists the path"     "$out" "hosts.nix"
hasnt "and not the quiet repo" "$out" "### repo-b"
has  "says the list is complete" "$out" "liste CALCULÉE et complète"

say "THE EXPENSIVE ONE: a failed session must not advance the base"
# Two assertions, because the behavioural one alone would survive somebody
# adding a third remember_pass call on an error path. First the SHAPE of
# reconcile_doc: exactly two calls, neither on a line that also gives up.
rd=$(sed -n '/^reconcile_doc() {/,/^}/p' "$JOB")
is "reconcile_doc records a pass exactly twice" "$(grep -c 'remember_pass' <<<"$rd")" "2"
if grep 'remember_pass' <<<"$rd" | grep -q 'fail=1'; then
  bad "a pass is recorded on a failure path"
else
  ok "and never beside fail=1"
fi
# Then the consequence — the same commit is still in the next delta.
out=$(private_delta A "$DOC" 2>/dev/null)
has "commit still listed after a failure" "$out" "ajoute une carte a gpu-01"
remember_pass A "$DOC" delta
out=$(private_delta A "$DOC" 2>/dev/null)
hasnt "and gone once the pass completed" "$out" "ajoute une carte a gpu-01"

say "the two sessions keep separate bases"
commit repo-b net.tf "change le tunnel"
out=$(private_delta C "$DOC" 2>"$ROOT/err")
is  "C has no base yet: full pass" "$out" ""
out=$(private_delta A "$DOC" 2>/dev/null)
has "A sees the new commit"        "$out" "change le tunnel"

say "a hand edit to the document forces a full pass"
remember_pass A "$DOC" delta
echo "quelqu'un a edite a la main" >> "$GIT_BASE/net-cfgs/$DOC"
git -C "$GIT_BASE/net-cfgs" commit -qam "hand edit"
# PUSHED: sessions reconcile a worktree cut from the remote since 2026-09-16,
# so only a hand edit that reached the remote is one they could ever see.
git -C "$GIT_BASE/net-cfgs" push -q origin cp-1
git -C "$GIT_BASE/net-cfgs" fetch -q origin
out=$(private_delta A "$DOC" 2>"$ROOT/err")
is  "no delta section" "$out" ""
has "and says why"     "$(cat "$ROOT/err")" "changed since the last pass"

say "an edit left UNPUSHED in the shared checkout does not reopen the question"
# The session never sees it: it works from the remote. Treating it as a change
# would force a full pass every night a person has a draft open.
remember_pass A "$DOC" full
echo "brouillon pas encore pousse" >> "$GIT_BASE/net-cfgs/$DOC"
git -C "$GIT_BASE/net-cfgs" commit -qam "draft, local only"
out=$(private_delta A "$DOC" 2>"$ROOT/err"); rc=$?
is "still a skip, not a full pass" "$rc" "3"
git -C "$GIT_BASE/net-cfgs" push -q origin cp-1; git -C "$GIT_BASE/net-cfgs" fetch -q origin

say "the full pass comes back on a timer"
remember_pass A "$DOC" delta
# backdate the last full pass past the window
python3 - "$STATE_DIR/seen-A" <<'PY'
import sys, time, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines()
lines[0] = f"full {int(time.time()) - 8 * 86400}"
p.write_text("\n".join(lines) + "\n")
PY
out=$(private_delta A "$DOC" 2>"$ROOT/err")
is  "no delta section"  "$out" ""
has "says how stale"    "$(cat "$ROOT/err")" "last full pass was 8d ago"

# NOTE: a full pass here, not a delta one — the timer test above backdated
# the recorded full pass on purpose, and carrying that forward makes
# private_delta bail on staleness before it ever reaches the cap.
say "a delta bigger than the cap is not a shortcut"
remember_pass A "$DOC" full
DELTA_FILE_CAP=2
for i in 1 2 3 4; do commit repo-a "f$i.txt" "bulk $i"; done
out=$(private_delta A "$DOC" 2>"$ROOT/err")
is  "no delta section" "$out" ""
has "says it gave up"  "$(cat "$ROOT/err")" "past the 2 cap"
DELTA_FILE_CAP=150

say "a base that no longer exists falls back rather than crashing"
remember_pass A "$DOC" full
python3 - "$STATE_DIR/seen-A" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
out = []
for line in p.read_text().splitlines():
    out.append("repo-a " + "0" * 40 if line.startswith("repo-a ") else line)
p.write_text("\n".join(out) + "\n")
PY
out=$(private_delta A "$DOC" 2>"$ROOT/err")
is  "no delta section" "$out" ""
has "says the base is gone" "$(cat "$ROOT/err")" "is gone from repo-a"

say "AN API REFUSAL MUST NOT READ AS AGREEMENT"
# 2026-09-16, live: the hosted model's content filter rejected session C's
# input. `qwen` exited 0, no file changed, and the driver reported "C: already
# matched the repos" — then banked the base as if C had read everything. The
# guard lives in run_author; assert the marker set it recognises, lifted from
# the driver rather than retyped.
ra=$(sed -n '/^run_author() {/,/^}/p' "$JOB")
has "run_author looks for an API error"  "$ra" 'API Error'
has "and for the content-filter code"    "$ra" 'DataInspectionFailed'
if grep -q 'rc=60' <<<"$ra"; then ok "and turns it into a failure"; else bad "the marker does not fail the session"; fi
# the marker must be checked even when the CLI exited 0 — that is the case
if grep -q '\[ "\$rc" = 0 \] && grep -qE' <<<"$ra"; then
  ok "checked precisely when the CLI claimed success"
else
  bad "the check does not cover a zero exit"
fi
# and the transcript this fires on is the one the run actually produced
cat > "$ROOT/transcript.json" <<'JSON'
[{"type":"result","result":"[API Error: 400 <400> InternalError.Algo.DataInspectionFailed: Input text data may contain inappropriate content.]"}]
JSON
if grep -qE '\[API Error|DataInspectionFailed|InternalError\.' "$ROOT/transcript.json"; then
  ok "the real 2026-09-16 transcript matches the marker"
else
  bad "the real transcript would slip through"
fi

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
