#!/bin/sh
# The Cronicle event "nixos-iac Drift Check", moved into git.
#
# The event itself is now a six-line bootstrap: install git+python3, clone this
# repo, run this script. Everything it used to do inline lives here, for the
# reason the GPU block already gave when IT was moved out on 2026-09-16 --
# "a script pasted into a Cronicle event is a script nobody reviews and nobody
# can test". The revision loop stayed behind that day, and it cost exactly
# what the comment predicted: it compared every host to cp-1, so the two
# canary hosts read STALE from every Sunday's flake.lock bump until the
# promotion, and when the promotion livelocked in September 2026 the check was
# red three days running with labodeludo.dev/architecture telling the public
# the diagram had drifted. It had not. Nobody could see the bug because
# nobody was looking at a diff.
#
# POSIX sh on purpose: the Cronicle worker is Alpine and has no bash.
#
# Environment (the event supplies these; nothing secret lives in this repo):
#   KUMA_PUSH_URL    push monitor for this job. Absent -> no heartbeat, said
#                    out loud rather than silently skipped.
#   DRIFT_KEY        ssh key for driftcheck@<host>   (default /keys/...)
#   DRIFT_REPO_KEY   ssh key for github              (default /keys/...)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
KEY=${DRIFT_KEY:-/keys/nixos-drift/id_ed25519}
REPO_KEY=${DRIFT_REPO_KEY:-/keys/nixos-drift/repo_ed25519}
KUMA_PUSH_URL=${KUMA_PUSH_URL:-}
REMOTE=${DRIFT_REMOTE:-git@github.com:ludorl82/nixos-iac.git}

push() { # push <up|down> <msg>
  [ -n "$KUMA_PUSH_URL" ] || { echo "drift: no KUMA_PUSH_URL — no heartbeat pushed"; return 0; }
  curl -fsSk -G "$KUMA_PUSH_URL" --data-urlencode "status=$1" --data-urlencode "msg=$2" >/dev/null \
    || echo "drift: kuma push failed (non-fatal)"
}

export GIT_SSH_COMMAND="ssh -i $REPO_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/nd_kh"
MASTER=$(git ls-remote "$REMOTE" refs/heads/cp-1 | cut -c1-40)
if [ -z "$MASTER" ]; then
  push down "nixos drift check broken: ls-remote failed"
  echo "drift: ls-remote failed"; exit 1
fi
# No canary branch is the normal state between bumps; an empty value simply
# means there is no second revision any host is allowed to be on.
CANARY=$(git ls-remote "$REMOTE" refs/heads/canary | cut -c1-40)
SHORT=$(echo "$MASTER" | cut -c1-7)
[ -n "$CANARY" ] && [ "$CANARY" != "$MASTER" ] \
  && echo "drift: cp-1 $SHORT, canary in flight $(echo "$CANARY" | cut -c1-7)" \
  || echo "drift: cp-1 $SHORT, no canary in flight"

# --- are the machines running what cp-1 says? ------------------------------
REV_OUT=$(python3 "$HERE/drift-revisions.py" "$ROOT" "$MASTER" "${CANARY:--}" --key "$KEY" 2>&1)
REV_RC=$?
echo "$REV_OUT"
REV_MSG=$(echo "$REV_OUT" | sed -n 's/^drift-revisions: //p')

# --- does the declared hardware match the metal? -----------------------------
# Unchanged in substance, and still a THIRD opinion rather than the source:
# a host that did not answer is UNVERIFIED and does not fail this job.
GPU_OUT=$(python3 "$HERE/gpu-discovery.py" "$ROOT" --key "$KEY" 2>&1)
GPU_RC=$?
echo "$GPU_OUT"
GPU_MSG=$(echo "$GPU_OUT" | sed -n 's/^gpu-discovery: //p')

if [ "$REV_RC" = 0 ] && [ "$GPU_RC" = 0 ]; then
  push up "${REV_MSG:-revisions ok}; ${GPU_MSG:-gpu ok}"
  exit 0
fi
if [ "$REV_RC" != 0 ]; then
  push down "nixos drift: ${REV_MSG:-revision check failed} (HEAD $SHORT)"
else
  push down "gpu inventory: ${GPU_MSG:-check failed} (HEAD $SHORT)"
fi
exit 1
