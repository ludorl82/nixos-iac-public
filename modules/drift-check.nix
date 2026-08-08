# Nightly configuration-revision drift check (Cronicle event "nixos-iac Drift
# Check"). A locked-down user whose key is bound to a single forced command:
# report which git revision built the running system. The checker compares
# every host's answer against origin/master HEAD and alerts through Kuma/ntfy
# when a host runs stale (or dirty-tree) config.
#
# configurationRevision itself is set flake-side (the inline driftModule in
# flake.nix) because it needs self.rev. Until a host is redeployed with that
# change it reports nothing and the check flags it as unverifiable — expected
# on first rollout.
#
# The private key lives only in the cronicle namespace Secret
# cronicle-ssh-nixos-drift (out-of-band, like every other cronicle-ssh-*).
{ pkgs, ... }:
{
  users.groups.driftcheck = { };

  users.users.driftcheck = {
    isSystemUser = true;
    group = "driftcheck";
    # A real shell is required for sshd to execute the forced command; the
    # "restrict" option (no pty, no forwarding, no X11) plus command= keeps
    # this key from doing anything but printing the revision.
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      ''command="/run/current-system/sw/bin/nixos-version --configuration-revision",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example hostcheck''
    ];
  };
}
