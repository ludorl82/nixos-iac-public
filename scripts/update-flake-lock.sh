#!/usr/bin/env bash
# Weekly flake.lock bump → the `canary` branch. Runs in the console container
# on console-vm (invoked by scripts/weekly-iac-updates.sh, the forced command of
# the Cronicle "Daily IaC updates" event, Sundays only).
#
# console-vm has no nix (deliberately — /nix was reclaimed 2026-07-27), so the
# lock update itself runs on gpu-01 over SSH: copy flake.nix+flake.lock to a
# temp dir there, `nix flake update`, copy the lock back.
#
# Since 2026-09-16 nobody merges this. The bump is pushed to `canary`, which
# the canary hosts (labo.canary = true: vm-01, vm-02) follow as comin's
# testing branch and switch to within minutes. A PR canary → cp-1 is opened
# for the eval gate and the paper trail; scripts/flake-canary.sh promotes it
# (fast-forward cp-1) after a day of healthy soak, or resets the branch on
# a red canary. This script never touches cp-1 directly.
#
# One rolling branch: if a canary is still in flight (canary ahead of cp-1)
# the bump is rebuilt on top of cp-1 and the branch force-pushed, so at
# most one canary is ever soaking and its clock restarts.
#
# Exit codes: 0 = ok (canary pushed, refreshed, or nothing to update),
# anything else = broken.
set -euo pipefail

WORK="$HOME/.iac-updates/nixos-iac"   # dedicated clone; never the interactive checkout
BRANCH="canary"
REMOTE_TMP="/tmp/flake-update.$$"

[ -d "$WORK/.git" ] || git clone -q git@github.com:ludorl82/nixos-iac.git "$WORK"
cd "$WORK"
git fetch -q origin --prune
git checkout -q cp-1
git reset -q --hard origin/cp-1

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
git commit -q -m "chore: weekly flake.lock update ($summary input(s) moved)" \
  -m "Pushed to canary; vm-01/vm-02 switch to it now, cp-1 follows after a day of soak (scripts/flake-canary.sh)."
git push -q -f origin "$BRANCH"

if gh pr list -R ludorl82/nixos-iac --head "$BRANCH" --state open --json number --jq length | grep -q '^0$'; then
  gh pr create -R ludorl82/nixos-iac --head "$BRANCH" --base cp-1 \
    --title "chore: weekly flake.lock update (canary)" \
    --body "Automated weekly input bump (Cronicle → console-vm → nix on gpu-01), on the \`canary\` branch.

**Nobody merges this.** vm-01 and vm-02 follow \`canary\` as comin's testing branch and switch to it within minutes. \`scripts/flake-canary.sh\` (daily, 20:00) fast-forwards cp-1 to it once both canaries have run it for 24 h reachable, \`running\` and Ready in k3s, and the eval check here is green; if a canary is unhealthy or never deployed it, the branch is reset to cp-1 and this PR is closed with the reason. Every other host, cloud-01 included, deploys on promotion." >&2
  echo "flake.lock: canary pushed, PR opened ($summary input(s) moved)"
else
  echo "flake.lock: canary refreshed ($summary input(s) moved), soak clock restarts"
fi
