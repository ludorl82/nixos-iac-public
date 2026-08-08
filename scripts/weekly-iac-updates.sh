#!/usr/bin/env bash
# Weekly IaC update PRs — the forced command of the Cronicle event
# "Weekly IaC update PRs" (dedicated key, port 2222, per the drift-check
# pattern). Orchestrates from console-vm:
#
#   1. nixos-iac: flake.lock bump via nix on gpu-01 → PR (eval gate tests it)
#   2. k3s-iac:   self-hosted Renovate → image tag-bump PRs
#
# Nothing here touches main/master on any repo: the PRs are the deliverable,
# review stays the gate, merge stays the deploy. Exit 0 = both halves ran;
# non-zero = something is broken (Cronicle marks the run failed).
set -u
export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin

rc=0

echo "=== nixos-iac flake.lock ==="
if ! "$HOME/git/ludorl82/nixos-iac/scripts/update-flake-lock.sh"; then
  echo "BROKEN: update-flake-lock.sh failed"
  rc=1
fi

echo "=== k3s-iac renovate ==="
# ~/k3s-iac, not ~/git/ludorl82/k3s-iac: the seeded console home keeps ONE
# checkout per repo (seed-console-home.sh); the old home's second checkout
# was exactly the stale-copy trap this layout retires.
if ! "$HOME/k3s-iac/scripts/renovate-run.sh"; then
  echo "BROKEN: renovate-run.sh failed"
  rc=1
fi

exit $rc
