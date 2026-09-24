# Store hygiene for every host. Nobody had ever asked for it: nixpkgs
# ships nix.gc and nix.optimise switched off, and nothing in this repo
# switched them on, so every deploy since the conversion left its dead paths
# behind for good.
#
# Learned on 2026-09-17, and not from `df -h`, which said 70 %: pi-01 ran
# out of INODES. 3.46 M of its 3.64 M were under /nix. comin then failed
# every pull with "no space left on device", stayed on 0be50f9 while cp-1
# moved 18 commits on, and the only symptom was nixos-iac drift (Kuma 42)
# going red at 04:31 — which in turn made nightly-diagram-sync skip A and C.
# vm-01, vm-02 and cloud-01 were at 77-79 % inodes the same morning.
#
# A full store blocks even its own cleanup: the gc socket, the profile lock
# and sqlite's journal all need a new inode, so `nix-store --gc` refuses to
# start until something else is deleted by hand.
#
# - gc: weekly, generations older than 14 days. Running systems, the booted
#   system and every generation younger than 14 days stay rooted (older
#   ones, comin's included, lose their rollback). The price: build-time-only
#   paths go too, and a Pi may rebuild the cheap remarshal chain (see
#   build-limits.nix) on its next config change. Cheaper than a host that
#   can no longer deploy.
# - optimise: hard-links identical files. That is what gives INODES back,
#   not just bytes — each duplicate collapses onto one inode.
# Both are Persistent, so a host that was off (the arcade VMs, vm-03)
# catches up at its next boot instead of skipping the week.
{ ... }:

{
  nix.gc = {
    automatic = true;
    dates = "Sun 03:15";
    randomizedDelaySec = "45min";
    persistent = true;
    options = "--delete-older-than 14d";
  };

  nix.optimise = {
    automatic = true;
    dates = [ "Sun 05:30" ];
    persistent = true;
  };
}
