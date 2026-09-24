#!/usr/bin/env bash
# Runs one console job DETACHED, logs it to a file, and follows it.
#
#   job-runner.sh <script> [args...]     (called by run-from-cp-1.sh)
#
# WHY (2026-09-16). Every Cronicle job on console-vm runs inside an ssh session
# the Cronicle pod holds open. When the cronicle Deployment was replaced that
# afternoon, the ssh carrying nightly-diagram-sync died with the old pod and
# SIGHUP took the job down mid-run. Its output existed only in Cronicle's job
# store, which lost the record too — and nothing reached Loki, because console-vm
# is not a k3s node and nothing shipped its logs at all.
#
# So every job now runs in its own session, writing its own log file, and this
# process only FOLLOWS it: it replays the log on stdout (Cronicle's job log
# reads as before) and exits with the job's own code. If the follower dies,
# only the follower dies. The job finishes, the file is complete, and
# modules/console-log-shipping.nix ships it to Loki as it is written — with
# `job=<script>` and `host=console-vm`.
#
# ONE RUN PER JOB. A job that outlives its caller could meet the next scheduled
# run of itself; a lock per job refuses the second one, loudly, with exit 0 so a
# Cronicle chain is not broken by an overlap it did not cause.
#
# This file lives in cp-1 and is fetched on every run. run-from-cp-1.sh,
# the one hand-copied file, only execs it — so the logic can change without
# anyone recopying anything.
set -euo pipefail

script="${1:?job-runner: which script?}"
shift
here="$(cd "$(dirname "$0")" && pwd)"
target="$here/$script"
job="${script%.sh}"; job="${job%.py}"

dir="${JOB_RUNNER_LOGS:-$HOME/.local/state/jobs}/$job"
mkdir -p "$dir"

exec 9> "$dir/.lock"
if ! flock -n 9; then
  echo "job-runner: $job is already running — not starting a second one"
  exit 0
fi

run="$dir/$(date -u +%Y%m%dT%H%M%SZ)-$$"
# A month of nights, per job. `|| true`: on a job's first run there is no log
# yet and `ls` exits non-zero, which under pipefail would end this silently.
{ ls -1t "$dir"/*.log 2>/dev/null | tail -n +31 | sed 's/\.log$//' \
    | while read -r old; do rm -f "$old".log "$old".rc "$old".pid; done; } || true

# The lock travels with the job: fd 9 is inherited by the detached session, so
# it is held for as long as the JOB lives, not just this follower.
# --norc --noprofile, and the ssh variables removed (2026-09-16). Debian's
# bash reads ~/.bashrc for a NON-interactive `bash -c` when SSH_CLIENT is set
# and SHLVL is low — exactly the situation under a Cronicle forced command.
# The console's ~/.bashrc does `exec zsh` before its interactive guard, so the
# detached child became a zsh reading /dev/null and exited 0 having run
# nothing: "never started", every job, from the moment this shipped. The
# tests had run in an interactive shell with a high SHLVL and could not see
# it. Stripping SSH_* also protects every `bash -c` the job itself spawns —
# the model sessions run their shell tools that way.
JOB_RUNNER=1 JOB_RC="$run.rc" \
  env -u SSH_CLIENT -u SSH2_CLIENT -u SSH_CONNECTION \
    setsid bash --norc --noprofile -c 'echo $$ > "$1"; shift; "$@"; echo $? > "$JOB_RC"' \
    _ "$run.pid" "$target" "$@" < /dev/null > "$run.log" 2>&1 &

for _ in $(seq 1 50); do [ -s "$run.pid" ] && break; sleep 0.1; done
if [ ! -s "$run.pid" ]; then
  echo "job-runner: $job never started (see $run.log)"
  exit 70
fi
# The follower no longer needs the lock; the job holds its own copy.
exec 9>&-

tail -n +1 -F --pid="$(cat "$run.pid")" "$run.log" 2>/dev/null || true
for _ in $(seq 1 50); do [ -s "$run.rc" ] && break; sleep 0.1; done
if [ -s "$run.rc" ]; then
  exit "$(cat "$run.rc")"
fi
echo "job-runner: $job ended without recording an exit code — killed? see $run.log"
exit 70
