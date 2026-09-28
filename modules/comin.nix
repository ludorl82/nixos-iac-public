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

    # BUILD TIMEOUT: 3 h instead of comin's default 30 min.
    #
    # The default killed gpu-01 on 2026-09-23. The weekly flake.lock bump had
    # soaked 74 h on the canaries and been promoted, and gpu-01 had to rebuild
    # ollama with CUDA plus the nvidia kernel modules. comin cancelled the
    # build at exactly 30 minutes — promotion at 12:27, the log stops dead
    # mid-CUDA-compile at 12:57 — and left gpu-01 on the previous generation.
    # Nothing said so: no error line, journald had suppressed 24,338 messages
    # of build output, and comin does not retry the same commit, so gpu-01 would
    # have sat there until the next unrelated merge. Rebuilding the same
    # derivation by hand without a limit succeeded with zero errors in 47.5
    # minutes, and that was a RESUMED build: the killed attempt had already
    # finished part of the closure. A cold one runs past the hour.
    #
    # Global, not per host: five of the twelve hosts compile nvidia (gpu-01,
    # gpu-02, gaming-01 and both arcades), and a per-host list is one
    # more thing to forget when a card moves — the failure labo.gpus exists to
    # prevent. The canaries could not catch this either: they are k3s VMs with
    # no GPU and never build that closure.
    #
    # The cost is honest and small: a genuinely hung build now takes up to
    # 3 h to be cancelled instead of 30 min. That is rare, and a host stuck on
    # an old generation shows up in the nightly drift check anyway.
    buildTimeout = 10800;
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
