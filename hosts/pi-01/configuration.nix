## Real per-host config for pi-01 (Pi5), built into a bootable nvmd
## nixos-raspberrypi SD/USB image. Same pattern as pi-02: the nvmd
## image itself creates the labeled FIRMWARE/NIXOS_SD partitions, this
## config references them and configures the rest. Networked + SSH, and a
## k3s agent via modules/k3s-agent.nix (rejoined 2026-07-24, the last two
## of the NixOS fleet to come back after the consolidation).
##
## Network: dual-homed over the single onboard NIC, exactly as the Debian
## pi-01 was - untagged frames are VLAN50 (203.0.113.131/23, secondary,
## no default route), VLAN10 rides tagged on top (192.0.2.131/23 +
## 2001:db8:50:a::83, carries the default route). Same shape as
## hosts/vm-03, which is the reference for the fleet.
##
## The NIC is **end0**, not eth0: the RPi vendor kernel's macb driver plus
## systemd's default naming policy lands on end0 on a Pi5 (verified on the
## running image, `networkctl status end0`). The earlier `eth0` match never
## matched anything, so vlan10 was never created and the box fell through
## to NetworkManager's DHCP on the untagged link - which is how it first
## showed up on VLAN50 instead of VLAN10.
{ config, pkgs, lib, nixpkgs, nixos-raspberrypi, ... }:
{
  imports = (with nixos-raspberrypi.nixosModules; [
    raspberry-pi-5.base
  ]) ++ [ ../../modules/k3s-agent.nix ../../modules/private-ca.nix ../../modules/ups-master.nix ../../modules/nas-wake.nix ];
  services.k3s.extraFlags = [ "--node-ip=192.0.2.131" ];

  # k3s from the *top-level* nixpkgs, not the one nixos-raspberrypi pins.
  #
  # The Pis are built by nixos-raspberrypi.lib.nixosInstaller, so their whole
  # pkgs set comes from that flake's own nixpkgs (NixOS 25.11) rather than
  # ours (26.11). That pin is deliberate and load-bearing -- it carries the
  # vendor kernel and Pi firmware -- so it must not be overridden wholesale.
  # But that nixpkgs stops at k3s_1_34, so it cannot supply the fleet's
  # version at all: this override is required, not just tidier.
  #
  # Overriding just this one package keeps the Pi-specific kernel/firmware
  # untouched. `nixpkgs.legacyPackages` (not an `import`) so it reuses the
  # already-evaluated, already-locked instance instead of a second one.
  # Overrides the mkDefault in modules/k3s-agent.nix -- keep the version
  # attribute here in step with that one.
  services.k3s.package = nixpkgs.legacyPackages.aarch64-linux.k3s_1_36;

  # The Pi 5 firmware prepends its own kernel args, including
  # `cgroup_disable=memory` - without countering it the k3s agent dies on
  # loop with `failed to find memory cgroup (v2)`. NixOS's cmdline.txt is
  # appended *after* the firmware's args and cgroup_enable/disable are
  # order-sensitive early params, so re-enabling here wins. Kernel cmdline
  # only takes effect at boot, so this needs a reboot, not just a switch.
  boot.kernelParams = [ "cgroup_enable=memory" "cgroup_memory=1" ];

  # 4G Pi with no disk swap: comin's nix eval of the weekly flake.lock bump
  # SIGBUS'd under memory pressure (pi-01, 2026-08-02) and the generation
  # is never retried. zram gives eval headroom without touching the NVMe.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  networking.hostName = "pi-01";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  # nvmd's installer image turns NetworkManager on; leaving it enabled means
  # two managers racing for end0 (NM won, with a DHCP lease). networkd only,
  # matching the rest of the fleet.
  networking.networkmanager.enable = lib.mkForce false;

  systemd.network.netdevs."10-vlan10" = {
    netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
    vlanConfig.Id = 10;
  };
  # Untagged = VLAN50. Secondary: address only, no gateway, and not required
  # for network-online so a VLAN50 hiccup can't hang boot.
  systemd.network.networks."10-end0" = {
    matchConfig.Name = "end0";
    vlan = [ "vlan10" ];
    address = [ "203.0.113.131/23" ];
    networkConfig.DHCP = "no";
    linkConfig.RequiredForOnline = "no";
  };
  # Tagged VLAN10 = primary. IPv6 follows the hex(last-octet) convention
  # (131 -> 0x83); the v6 default route comes from pfSense's RA, same as
  # vm-03. "~." forces every lookup at pfSense's Unbound, without which
  # systemd-resolved falls back to public resolvers that can't see lab.example.
  systemd.network.networks."20-vlan10" = {
    matchConfig.Name = "vlan10";
    address = [
      "192.0.2.131/23"
      "2001:db8:50:a::83/64"
    ];
    routes = [ { Gateway = "192.0.2.254"; } ];
    networkConfig = {
      DNS = "192.0.2.254";
      IPv6AcceptRA = true;
    };
    domains = [ "lab.example" "example.com" "~." ];
  };
  networking.search = [ "lab.example" "example.com" ];

  users.users.ludorl82 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  # mkForce: this config is layered into nvmd's installer-image builder,
  # which also sets stateVersion (from the nixpkgs release) - ours wins.
  system.stateVersion = lib.mkForce "26.05";
}
