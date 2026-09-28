#!/usr/bin/env bash
# Daily IaC updates — the forced command of the Cronicle event
# "Daily IaC updates" (dedicated key, port 2222, per the drift-check
# pattern; was "Weekly IaC update PRs" until 2026-09-16). Orchestrates from
# console-vm:
#
#   1. nixos-iac: flake.lock bump via nix on gpu-01 → PR (eval gate tests it).
#      Sundays only, so the PR is refreshed once a week, not churned daily.
#   2. k3s-iac:   self-hosted Renovate → one PR per image bump, AUTOMERGED
#      by Renovate after each tier's release age (k3s-iac renovate.json).
#      Daily, because Renovate merges at most one PR per run and never the
#      one it just opened — a weekly cadence would take a month to drain a
#      Sunday. The k3s-iac iac-gate CronJob reverts a merge that goes red.
#
# Since 2026-09-16 nobody merges by hand: half 2 lands on main by itself and
# is tested after the fact by the gate. Half 1 still stops at the PR until
# the comin testing-branch canary exists for nixos-iac.
#
# Exit 0 = every half that ran finished; non-zero = something is broken
# (Cronicle marks the run failed).
set -u
export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin

# One forced-command key, two Cronicle events. Before 18:00 this is the
# morning updates run; from 18:00 it is the evening "nixos-iac canary
# promotion" event, which only judges the flake.lock canary (promote after a
# day of soak, or roll back) — in the evening because the promoted fleet
# rebuild includes the Pi, which is slow, and the night is when nobody needs
# the jumphost. The hour, not an argument: a forced-command key that took
# arguments would give back the generality the restriction exists to remove.
if [ "$(date +%H)" -ge 18 ]; then
  echo "=== nixos-iac flake.lock canary: promote or roll back ==="
  exec "$HOME/git/ludorl82/nixos-iac/scripts/flake-canary.sh"
fi

rc=0

if [ "$(date +%u)" = 7 ]; then
  echo "=== nixos-iac flake.lock ==="
  if ! "$HOME/git/ludorl82/nixos-iac/scripts/update-flake-lock.sh"; then
    echo "BROKEN: update-flake-lock.sh failed"
    rc=1
  fi
else
  echo "=== nixos-iac flake.lock: Sundays only, skipped ==="
fi

echo "=== k3s-iac renovate ==="
# Run the runner that is in k3s-iac main, from a clone this job owns — not
# from ~/k3s-iac (a seeded checkout nothing refreshes) and not from
# ~/git/ludorl82/k3s-iac (a person's working tree). Same reasoning as
# run-from-cp-1.sh: a green job must be able to say which version ran, and
# a failed fetch is loud rather than a silent fall-back to yesterday's code.
k3s_repo="$HOME/.cache/k3s-iac"
k3s_remote="git@github.com:ludorl82/k3s-iac.git"
if [ ! -d "$k3s_repo/.git" ]; then
  mkdir -p "$(dirname "$k3s_repo")"
  git clone -q "$k3s_remote" "$k3s_repo" || { echo "BROKEN: cannot clone k3s-iac"; exit 1; }
fi
if git -C "$k3s_repo" fetch -q "$k3s_remote" main \
   && git -C "$k3s_repo" reset -q --hard FETCH_HEAD \
   && git -C "$k3s_repo" clean -qfdx; then
  echo "k3s-iac at $(git -C "$k3s_repo" rev-parse --short HEAD)"
  if ! "$k3s_repo/scripts/renovate-run.sh"; then
    echo "BROKEN: renovate-run.sh failed"
    rc=1
  fi
else
  echo "BROKEN: cannot fetch k3s-iac main"
  rc=1
fi

exit $rc
