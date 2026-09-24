# comin: pull-based GitOps for the fleet. The host polls the repo, builds its
# own nixosConfiguration (matched by hostname) and switches when cp-1 moves.
# Merge to cp-1 IS the deploy; PR review (the eval check in
# .github/workflows/check.yml) is the only gate before it.
#
# The repo is private, so each enrolled host carries a read-only fine-grained
# GitHub PAT (contents: read, this repo only) at /etc/comin/github-token —
# distributed out-of-band like every other secret, never in git:
#
#   install -D -m 0600 <token-file> /etc/comin/github-token
#
# Rollback story: comin switches generations like nixos-rebuild does, so a bad
# deploy is `nixos-rebuild switch --rollback` (or the boot menu) away — except
# on a host that lost SSH, which is why enrollment goes canary-first and cloud-01
# (sole k3s control-plane; recovery = EC2 serial console) enrolls last.
#
# CANARY (2026-09-16, "nobody merges"). Hosts with `labo.canary = true` also
# follow the `canary` branch as comin's testing branch. The weekly flake.lock
# bump is pushed there (scripts/update-flake-lock.sh) instead of waiting for a
# person to merge a PR; the canaries build and SWITCH to it within minutes
# (operation "switch", not comin's default "test", so a reboot keeps the
# canary generation and the reboot path is exercised too). After a day of
# soak with the hosts reachable, `running`, and Ready in k3s,
# scripts/flake-canary.sh fast-forwards cp-1 to it and every other host
# follows; if the canaries are unhealthy or never deployed it, the branch is
# reset to cp-1 and the canaries switch back on their own. comin only
# deploys the testing branch while it is strictly ahead of cp-1, so a reset
# IS the rollback.
{ lib, config, ... }:
{
  options.labo.canary = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Follow the `canary` branch as comin's testing branch. Set on the
      expendable hosts (the two k3s VMs) — never on cloud-01 (sole control-plane),
      the jumphost, or a GPU host.
    '';
  };

  config.services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/ludorl82/nixos-iac.git";
        auth.access_token_path = "/etc/comin/github-token";
        # `//` is shallow: merging at the `branches` level, not above it, or
        # the testing entry would replace main and the host would follow a
        # branch called "main" that does not exist (caught in eval 2026-09-16).
        branches = {
          main.name = "cp-1";
        } // lib.optionalAttrs config.labo.canary {
          testing = {
            name = "canary";
            operation = "switch";
          };
        };
      }
    ];
  };
}
# CI note: PRs are gated by .github/workflows/check.yml (eval of every host);
# merge to cp-1 is deployed by comin on every enrolled host.
