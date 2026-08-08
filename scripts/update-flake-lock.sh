#!/usr/bin/env bash
# Weekly flake.lock bump → PR. Runs in the console container on console-vm
# (invoked by scripts/../..: ~/scripts/weekly-iac-updates.sh, itself the
# forced command of the Cronicle "Weekly IaC update PRs" event).
#
# console-vm has no nix (deliberately — /nix was reclaimed 2026-07-27), so the
# lock update itself runs on gpu-01 over SSH: copy flake.nix+flake.lock to a
# temp dir there, `nix flake update`, copy the lock back. The PR is the
# deliverable; the eval gate tests it and a human merges it — comin does the
# rest. This script never touches master directly.
#
# Exit codes: 0 = ok (PR opened, refreshed, or nothing to update),
# anything else = broken.
set -euo pipefail

WORK="$HOME/.iac-updates/nixos-iac"   # dedicated clone; never the interactive checkout
BRANCH="chore/flake-update"           # one rolling branch — force-pushed weekly,
                                      # so at most one update PR is ever open
REMOTE_TMP="/tmp/flake-update.$$"

[ -d "$WORK/.git" ] || git clone -q git@github.com:ludorl82/nixos-iac.git "$WORK"
cd "$WORK"
git fetch -q origin
git checkout -q master
git reset -q --hard origin/master

ssh gpu-01.lab.example "mkdir -p $REMOTE_TMP"
trap 'ssh gpu-01.lab.example "rm -rf $REMOTE_TMP" 2>/dev/null || true' EXIT
scp -q flake.nix flake.lock "gpu-01.lab.example:$REMOTE_TMP/"
ssh gpu-01.lab.example "cd $REMOTE_TMP && nix --extra-experimental-features 'nix-command flakes' flake update" >&2
scp -q "gpu-01.lab.example:$REMOTE_TMP/flake.lock" flake.lock

if git diff --quiet flake.lock; then
  echo "flake.lock: no updates this week"
  exit 0
fi

summary=$(git diff flake.lock | grep -c '^+.*"lastModified"' || true)
git checkout -q -B "$BRANCH"
git add flake.lock
git commit -q -m "chore: weekly flake.lock update ($summary input(s) moved)"
git push -q -f origin "$BRANCH"

if gh pr list -R ludorl82/nixos-iac --head "$BRANCH" --state open --json number --jq length | grep -q '^0$'; then
  gh pr create -R ludorl82/nixos-iac --head "$BRANCH" \
    --title "chore: weekly flake.lock update" \
    --body "Automated weekly input bump (Cronicle → console-vm → nix on gpu-01).

Merging deploys the fleet via comin. Reminders from the backlog: merge in the
evening (Pi rebuild tail), and check k3s release notes if nixpkgs moved its
k3s version — cloud-01 (sole control-plane) deploys unattended." >&2
  echo "flake.lock: PR opened ($summary input(s) moved)"
else
  echo "flake.lock: existing PR refreshed ($summary input(s) moved)"
fi
