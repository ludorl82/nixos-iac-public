# Lets a deploy be driven from another machine in the fleet.
#
# `nixos-rebuild --target-host` builds the closure locally and pushes it to
# the target, which did not build it. The receiving nix-daemon refuses store
# paths that carry no signature from a key it trusts, unless the SSH user
# pushing them is itself trusted:
#
#   error: cannot add path '/nix/store/...-nixos-version'
#          because it lacks a signature by a trusted key
#
# The fleet never hit this during the original install because nixos-anywhere
# connects as root, and root is trusted unconditionally -- so the gap only
# showed up the first time a deploy ran as ludorl82 from a peer host.
#
# This grants no privilege that isn't already held: ludorl82 is in wheel with
# security.sudo.wheelNeedsPassword = false on every host, so it can already
# become root there.
#
# trusted-users is a list option, so module values are concatenated rather
# than overridden -- root arrives from the nixpkgs default and does not need
# listing here (pi-01/pi-02 also pick up "nixos" from nixos-raspberrypi).
{ ... }:

{
  nix.settings.trusted-users = [ "ludorl82" ];

  # nixos-raspberrypi's cachix serves the prebuilt Pi vendor kernels.
  # Without it, any host (or gpu-01 via binfmt) that needs a Pi kernel not in
  # cache.nixos.org COMPILES it — discovered 2026-08-05 when the first
  # docker-rpi4 image build spent 40 min building a kernel under qemu.
  # Key fetched from the cachix API, not transcribed from memory.
  nix.settings.substituters = [ "https://nixos-raspberrypi.cachix.org" ];
  nix.settings.trusted-public-keys = [
    "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
  ];
}
