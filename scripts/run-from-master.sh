#!/usr/bin/env bash
# The one file under ~/scripts that is NOT a copy of cp-1 — and the reason
# none of the others has to be one any more.
#
# WHY THIS EXISTS (2026-09-16). Every Cronicle forced-command key on console-vm
# named ~/scripts/<name>, a file copied there by hand out of this repo.
# Nothing synced it and nothing watched it, so merging to cp-1 changed
# nothing until somebody remembered to copy the file across. That morning the
# daily chain ran the 2026-09-13 copy of daily-gpu-01-sync.sh — two commits
# stale — and both missing commits mattered:
#
#   * check-answerable.py did not exist yet, so the suggested-questions panel
#     published « T'as un article sur Proxmox ? », which production answers
#     « ça, c'est pas documenté ». The site's own button led to a dead end.
#   * the session that picks the questions had no ASK_BACKEND=ollama pin, so
#     it ran on the hosted model and the counted list of visitor questions
#     went to Alibaba Cloud. The site promises those stay in the lab.
#
# Neither was visible. The job was green, and "nixos-iac Drift Check" compares
# each host's system.configurationRevision — which says nothing about a
# directory inside a container's bind-mounted home.
#
# So the copies go away. The forced command names a script, this fetches
# cp-1, and runs the one that is in cp-1.
#
# LOUD BEATS STALE. A failed fetch exits non-zero: Cronicle shows red and the
# chain's absence-shaped Kuma monitors fire. Falling back to the clone already
# on disk would be running yesterday's code quietly, which is precisely the
# failure being replaced — so it is never the fallback.
#
# It prints the commit it ran. "Which version was that?" is then answered by
# the job log, instead of by a stat(1) on a file nobody thought to look at.
#
# KEEP IT SMALL. This file is still copied by hand, because something has to
# bootstrap. The defence is that it is short enough never to need editing. It
# compares itself against cp-1 after fetching and warns when they differ, so
# a stale bootstrap is at least not a silent one.
#
# Usage, from an authorized_keys forced command:
#   command="/home/ludorl82/scripts/run-from-cp-1.sh arch-refresh.sh"
set -euo pipefail
export PATH="$HOME/.local/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

name="${1:?run-from-cp-1: which script?}"
shift

# Its OWN clone, never ~/git/ludorl82/nixos-iac: that one is a person's working
# tree with branches and unstaged edits, and the `reset --hard` below would
# throw them away every morning.
repo="${RUN_FROM_MASTER_REPO:-$HOME/.cache/nixos-iac}"
remote="${RUN_FROM_MASTER_REMOTE:-git@github.com:ludorl82/nixos-iac.git}"

if [ ! -d "$repo/.git" ]; then
  mkdir -p "$(dirname "$repo")"
  git clone -q "$remote" "$repo"
fi
# The URL, not the remote name. `fetch origin` would use whatever URL the
# clone was created with, so changing the line above would change nothing on a
# box that already has the clone — the same shape of staleness this file
# exists to end, one level down.
git -C "$repo" fetch -q "$remote" cp-1
git -C "$repo" reset -q --hard FETCH_HEAD
git -C "$repo" clean -qfdx

target="$repo/scripts/$name"
[ -f "$target" ] || { echo "run-from-cp-1: cp-1 has no scripts/$name" >&2; exit 1; }
# git carries the mode, so a target that is not executable in cp-1 is a
# packaging mistake worth saying out loud rather than papering over with a
# `bash` prefix — that prefix would also silently ignore a python shebang.
[ -x "$target" ] || { echo "run-from-cp-1: scripts/$name is not executable in cp-1" >&2; exit 1; }

echo "run-from-cp-1: $name at $(git -C "$repo" rev-parse --short HEAD)"
cmp -s "$0" "$repo/scripts/run-from-cp-1.sh" \
  || echo "run-from-cp-1: WARNING — this bootstrap differs from cp-1, recopy it" >&2

# Through job-runner.sh when cp-1 has it: the job runs detached, logs to
# ~/.local/state/jobs/<job>/, and survives the ssh that started it. The
# fallback keeps an older cp-1 runnable — this file outlives the commits it
# is copied from.
if [ -x "$repo/scripts/job-runner.sh" ]; then
  exec "$repo/scripts/job-runner.sh" "$name" "$@"
fi
exec "$target" "$@"
