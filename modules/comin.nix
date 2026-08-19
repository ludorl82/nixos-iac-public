# comin: pull-based GitOps for the fleet. The host polls the repo, builds its
# own nixosConfiguration (matched by hostname) and switches when cp-1 moves.
# Merge to cp-1 IS the deploy; PR review (the eval check in
# .github/workflows/check.yml) is the only gate.
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
{ ... }:
{
  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/ludorl82/nixos-iac.git";
        auth.access_token_path = "/etc/comin/github-token";
        branches.main.name = "cp-1";
      }
    ];
  };
}
# CI note: PRs are gated by .github/workflows/check.yml (eval of every host);
# merge to cp-1 is deployed by comin on enrolled hosts (vm-01 so far).
