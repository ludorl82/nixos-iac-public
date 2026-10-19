#!/usr/bin/env bash
# Tests for run-from-cp-1.sh — the bootstrap that ended the hand-copied
# ~/scripts directory.
#
# What has to be true, and why each one is here rather than assumed:
#
#   * it runs the version in cp-1, not the version already on disk. That IS
#     the bug it replaces: on 2026-09-16 the daily job ran a copy three days
#     old and published a dead-end question with a gate that existed in cp-1
#     but not on the box.
#   * a fetch that fails STOPS the job. Falling back to the clone on disk
#     would be the old failure with extra steps, so the test asserts a
#     non-zero exit and that the stale script never ran.
#   * arguments and the exit code pass straight through, because Cronicle
#     reads the exit code and some of these scripts take arguments.
#   * an unknown or non-executable target fails loudly instead of silently
#     doing nothing.
#   * it notices when the bootstrap itself has drifted from cp-1 — the one
#     file that is still copied by hand.
#
# Nothing leaves the machine: the "remote" is a local bare repository, so the
# real git codepaths run for real without touching GitHub.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT="$SCRIPTS/run-from-cp-1.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/runfrommaster-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', wanted '$3'"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: '$2' lacks '$3'";; esac; }

[ -x "$BOOT" ] || { echo "run-from-cp-1.sh missing or not executable"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# --- a local "GitHub": a bare repo with a cp-1 branch -------------------
SRC="$ROOT/src"
REMOTE="$ROOT/remote.git"
mkdir -p "$SRC/scripts"
git init -q -b cp-1 "$SRC"
cp "$BOOT" "$SRC/scripts/run-from-cp-1.sh"
chmod +x "$SRC/scripts/run-from-cp-1.sh"
cat > "$SRC/scripts/demo.sh" <<'EOF'
#!/usr/bin/env bash
echo "VERSION=one args=$*"
exit 0
EOF
chmod +x "$SRC/scripts/demo.sh"
git -C "$SRC" add -A
git -C "$SRC" commit -qm one
git clone -q --bare "$SRC" "$REMOTE"

REPO="$ROOT/clone"
run() { RUN_FROM_MASTER_REPO="$REPO" RUN_FROM_MASTER_REMOTE="$REMOTE" "$BOOT" "$@" 2>&1; }

say "first run clones and executes"
out=$(run demo.sh alpha beta); rc=$?
is   "exit code passes through" "$rc" "0"
has  "ran the target"           "$out" "VERSION=one"
has  "arguments pass through"   "$out" "args=alpha beta"
has  "prints the commit it ran" "$out" "run-from-cp-1: demo.sh at"

say "a new cp-1 commit is picked up WITHOUT touching the box"
sed -i 's/VERSION=one/VERSION=two/' "$SRC/scripts/demo.sh"
git -C "$SRC" commit -qam two
git -C "$SRC" push -q "$REMOTE" cp-1
out=$(run demo.sh)
has "second run got the new version" "$out" "VERSION=two"

say "local edits to the clone are thrown away, never preferred"
echo 'echo "TAMPERED"' >> "$REPO/scripts/demo.sh"
echo "junk" > "$REPO/scripts/untracked.sh"
out=$(run demo.sh)
has  "the edit is gone"        "$out" "VERSION=two"
case "$out" in *TAMPERED*) bad "tampered copy ran";; *) ok "tampered copy did not run";; esac
[ -e "$REPO/scripts/untracked.sh" ] && bad "untracked file survived" || ok "untracked file cleaned"

say "the target's exit code is the bootstrap's exit code"
cat > "$SRC/scripts/fails.sh" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$SRC/scripts/fails.sh"
git -C "$SRC" add -A; git -C "$SRC" commit -qm fails; git -C "$SRC" push -q "$REMOTE" cp-1
run fails.sh >/dev/null 2>&1
is "exit 42 survives the exec" "$?" "42"

say "a fetch that fails STOPS — it never runs what is on disk"
out=$(RUN_FROM_MASTER_REPO="$REPO" RUN_FROM_MASTER_REMOTE="$ROOT/does-not-exist.git" \
        "$BOOT" demo.sh 2>&1); rc=$?
[ "$rc" = 0 ] && bad "a dead remote exited 0" || ok "a dead remote is non-zero (rc=$rc)"
case "$out" in *VERSION=*) bad "ran the stale copy anyway";; *) ok "did not run the stale copy";; esac

say "unknown and non-executable targets fail loudly"
out=$(run nope.sh 2>&1); rc=$?
is  "unknown target is non-zero" "$rc" "1"
has "and says which"             "$out" "cp-1 has no scripts/nope.sh"

cat > "$SRC/scripts/plain.sh" <<'EOF'
#!/usr/bin/env bash
echo "SHOULD NOT RUN"
EOF
chmod -x "$SRC/scripts/plain.sh"
git -C "$SRC" add -A; git -C "$SRC" commit -qm plain; git -C "$SRC" push -q "$REMOTE" cp-1
out=$(run plain.sh 2>&1); rc=$?
[ "$rc" = 0 ] && bad "non-executable target exited 0" || ok "non-executable target is non-zero"
has "and says why" "$out" "not executable in cp-1"

say "a bootstrap that has drifted from cp-1 says so"
DRIFTED="$ROOT/drifted.sh"
{ cat "$BOOT"; echo "# hand edit nobody pushed"; } > "$DRIFTED"
chmod +x "$DRIFTED"
out=$(RUN_FROM_MASTER_REPO="$REPO" RUN_FROM_MASTER_REMOTE="$REMOTE" "$DRIFTED" demo.sh 2>&1)
has "warns about itself" "$out" "differs from cp-1"
has "but still runs"     "$out" "VERSION=two"

# --------------------------------------------------------------------------
# Through job-runner.sh (2026-09-16): every job detached, logged, followed.
# Same fake remote, now with the REAL runner copied into its cp-1.
# --------------------------------------------------------------------------
cp "$SCRIPTS/job-runner.sh" "$SRC/scripts/job-runner.sh"
chmod +x "$SRC/scripts/job-runner.sh"
cat > "$SRC/scripts/slow.sh" <<'EOF'
#!/usr/bin/env bash
echo "SLOW start runner=${JOB_RUNNER:-unset}"
sleep 3
echo "SLOW end"
exit 7
EOF
chmod +x "$SRC/scripts/slow.sh"
git -C "$SRC" add -A; git -C "$SRC" commit -qm runner; git -C "$SRC" push -q "$REMOTE" cp-1
LOGS="$ROOT/jobs"
runj() { RUN_FROM_MASTER_REPO="$REPO" RUN_FROM_MASTER_REMOTE="$REMOTE" JOB_RUNNER_LOGS="$LOGS" "$BOOT" "$@" 2>&1; }

say "a job run through the runner behaves like before, from the outside"
out=$(runj demo.sh alpha); rc=$?
is  "exit code passes through"  "$rc" "0"
has "output is replayed"        "$out" "args=alpha"
ls "$LOGS"/demo/*.log >/dev/null 2>&1 && ok "and a log file exists for the run" || bad "and a log file exists for the run"
grep -q "args=alpha" "$LOGS"/demo/*.log 2>/dev/null && ok "holding the job's own output" || bad "holding the job's own output"
run fails.sh >/dev/null 2>&1   # fallback path already covered above
out=$(runj fails.sh); rc=$?
is  "a failing job's code survives the runner" "$rc" "42"

say "the job is told it is being run by the runner"
out=$(runj slow.sh); rc=$?
has "JOB_RUNNER=1 reaches it" "$out" "runner=1"
is  "and its exit code comes back" "$rc" "7"

say "THE 2026-09-16 FAILURE: the follower dies, the job does not"
rm -rf "$LOGS/slow"
( setsid bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$ROOT/follower.pid" \
    env RUN_FROM_MASTER_REPO="$REPO" RUN_FROM_MASTER_REMOTE="$REMOTE" JOB_RUNNER_LOGS="$LOGS" "$BOOT" slow.sh ) \
  > "$ROOT/follower.out" 2>&1 &
for _ in $(seq 1 50); do [ -s "$ROOT/follower.pid" ] && break; sleep 0.1; done
for _ in $(seq 1 50); do ls "$LOGS"/slow/*.pid >/dev/null 2>&1 && break; sleep 0.1; done
sleep 1
kill -HUP -- "-$(cat "$ROOT/follower.pid")" 2>/dev/null
rcf=""
for _ in $(seq 1 80); do rcf=$(ls "$LOGS"/slow/*.rc 2>/dev/null | head -1); [ -n "$rcf" ] && break; sleep 0.1; done
[ -n "$rcf" ] && ok "the job still finished and recorded its code" || bad "the job still finished and recorded its code"
is "the code is the job's own" "$(cat "$rcf" 2>/dev/null)" "7"
grep -q "SLOW end" "$LOGS"/slow/*.log 2>/dev/null && ok "and its log is complete" || bad "and its log is complete"

say "THE CONTEXT THE FIRST VERSION NEVER SAW: a Cronicle forced command"
# Under sshd, Debian's bash reads ~/.bashrc for a non-interactive `bash -c`
# when SSH_CLIENT is set and SHLVL is low. The console's ~/.bashrc does
# `exec zsh` before its interactive guard, so the detached child ran NOTHING
# and exited 0 — every job "never started" in production, while every test
# above passed in an interactive shell. Replayed here with a hostile home.
HOSTILE="$ROOT/hostile-home"; mkdir -p "$HOSTILE"
# the same shape as the real line: replace the shell before any guard
printf 'exec true\n' > "$HOSTILE/.bashrc"
rm -rf "$LOGS/demo"
out=$(env -u SHLVL HOME="$HOSTILE" SSH_CLIENT="198.51.100.1 50000 2222" SSH_CONNECTION="198.51.100.1 50000 198.51.100.2 2222" \
        RUN_FROM_MASTER_REPO="$REPO" RUN_FROM_MASTER_REMOTE="$REMOTE" JOB_RUNNER_LOGS="$LOGS" \
        "$BOOT" demo.sh beta < /dev/null 2>&1); rc=$?
is  "the job still starts under an sshd-like environment" "$rc" "0"
has "and runs"                                          "$out" "args=beta"
# the SSH variables must not reach the job either: its own `bash -c` children
# (the model sessions' shell tools) would be hijacked the same way
cat > "$SRC/scripts/envcheck.sh" <<'EOF'
#!/usr/bin/env bash
echo "SSH_CLIENT=${SSH_CLIENT:-unset}"
bash -c 'echo nested-bash-ran'
EOF
chmod +x "$SRC/scripts/envcheck.sh"
git -C "$SRC" add -A; git -C "$SRC" commit -qm envcheck; git -C "$SRC" push -q "$REMOTE" cp-1
out=$(env -u SHLVL HOME="$HOSTILE" SSH_CLIENT="198.51.100.1 50000 2222" \
        RUN_FROM_MASTER_REPO="$REPO" RUN_FROM_MASTER_REMOTE="$REMOTE" JOB_RUNNER_LOGS="$LOGS" \
        "$BOOT" envcheck.sh < /dev/null 2>&1)
has "the job does not inherit SSH_CLIENT"   "$out" "SSH_CLIENT=unset"
has "so a bash -c inside the job still runs" "$out" "nested-bash-ran"

say "a second run of the same job while one is alive does nothing"
rm -rf "$LOGS/slow"
runj slow.sh > "$ROOT/first.out" 2>&1 &
first=$!
for _ in $(seq 1 50); do ls "$LOGS"/slow/*.pid >/dev/null 2>&1 && break; sleep 0.1; done
out=$(runj slow.sh); rc=$?
has "it says so"           "$out" "slow is already running"
is  "exit 0, not an error" "$rc" "0"
wait "$first"
is  "and the first run was not disturbed" "$(ls "$LOGS"/slow/*.log | wc -l)" "1"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
