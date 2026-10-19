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
# The canary exception applies ONLY while the canary branch is strictly AHEAD
# of cp-1 — the same rule comin itself uses to decide whether to deploy a
# testing branch. The first version of this script (#77) granted it whenever
# the two refs merely DIFFERED, and the branch is behind cp-1 most of the
# time: the judge resets it onto cp-1, then the next merge moves cp-1 on
# and leaves it trailing. On 2026-09-25 the log read "canary in flight
# 4c2d437" when 4c2d437 was an ordinary cp-1 merge two commits old and
# nothing was in flight at all. The cost was not the wording: a canary host
# stuck on that old commit would have been reported "ok (canary)" instead of
# STALE, so the exception would have hidden exactly the drift this job
# exists to catch.
#
# Ancestry needs history, and the checkout this runs from is a --depth 1
# clone. The fetch goes into a THROWAWAY bare repository, never into $ROOT:
# a shallow fetch into a full clone converts it to shallow. Every way this
# can fail — no canary branch, fetch error, history too shallow — lands on
# "not ahead", i.e. the exception is withheld. That is the safe direction: a
# wrongly withheld exception is a visible red on a canary, a wrongly granted
# one is silence.
CANARY=$(git ls-remote "$REMOTE" refs/heads/canary | cut -c1-40)
SHORT=$(echo "$MASTER" | cut -c1-7)
AHEAD=0
if [ -n "$CANARY" ] && [ "$CANARY" != "$MASTER" ]; then
  HIST=$(mktemp -d "${TMPDIR:-/tmp}/drift-hist.XXXXXX")
  if git init -q --bare "$HIST" \
     && git -C "$HIST" fetch -q --depth=50 "$REMOTE" \
          "refs/heads/cp-1:refs/m" "refs/heads/canary:refs/c" 2>/dev/null \
     && git -C "$HIST" merge-base --is-ancestor "$MASTER" "$CANARY" 2>/dev/null; then
    AHEAD=1
  fi
  rm -rf "$HIST"
fi
if [ "$AHEAD" = 1 ]; then
  echo "drift: cp-1 $SHORT, canary in flight $(echo "$CANARY" | cut -c1-7) (ahead of cp-1)"
else
  [ -n "$CANARY" ] && [ "$CANARY" != "$MASTER" ] \
    && echo "drift: cp-1 $SHORT, canary branch at $(echo "$CANARY" | cut -c1-7) is NOT ahead of cp-1 — no exception" \
    || echo "drift: cp-1 $SHORT, no canary in flight"
  CANARY=""
fi

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
