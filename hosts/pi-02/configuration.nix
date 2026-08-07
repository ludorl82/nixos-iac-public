## Real per-host config for pi-02 (Pi5), built into a bootable nvmd
## nixos-raspberrypi image via lib.nixosInstaller (same as pi-01). The
## installer builder provides the FIRMWARE/NIXOS_SD fileSystems, so this
## config doesn't declare them. Networked + SSH, and a k3s agent via
## modules/k3s-agent.nix (rejoined 2026-07-24). pi-02's SD slot is
## broken, so USB is its only boot path - proven working with the nvmd
## kernel-boot image.
##
## Network: dual-homed over the single onboard NIC, as the Debian pi-02
## was - untagged frames are VLAN50 (203.0.113.132/23, secondary, no
## default route), VLAN10 rides tagged on top (192.0.2.132/23 +
## 2001:db8:50:a::84, carries the default route). See
## hosts/pi-01/configuration.nix for the end0-vs-eth0 note; identical
## here.
{ config, pkgs, lib, nixpkgs, nixos-raspberrypi, ... }:
{
  imports = (with nixos-raspberrypi.nixosModules; [
    raspberry-pi-5.base
  ]) ++ [ ../../modules/k3s-agent.nix ../../modules/private-ca.nix ../../modules/ups-master.nix ../../modules/rack-wake.nix ../../modules/house-heartbeat.nix ../../modules/console-host.nix ../../modules/ha-backup.nix ];
  services.k3s.extraFlags = [ "--node-ip=192.0.2.132" ];

  # See pi-01 for the full reasoning: the Pi builds come from
  # nixos-raspberrypi's pinned nixpkgs (25.11), which stops at k3s_1_34 and
  # so cannot supply the fleet's version, hence k3s alone comes from the
  # top-level nixpkgs. Only this package is overridden -- the vendor kernel
  # and Pi firmware must keep coming from the pinned set. Overrides the
  # mkDefault in modules/k3s-agent.nix; keep the version in step with it.
  services.k3s.package = nixpkgs.legacyPackages.aarch64-linux.k3s_1_36;

  # See pi-01: the Pi 5 firmware's `cgroup_disable=memory` has to be
  # countered or the k3s agent can't start. Requires a reboot.
  boot.kernelParams = [ "cgroup_enable=memory" "cgroup_memory=1" ];

  # 4G Pi with no disk swap: comin's nix eval of the weekly flake.lock bump
  # SIGBUS'd under memory pressure (pi-01, 2026-08-02) and the generation
  # is never retried. zram gives eval headroom without touching the NVMe.
  # 2026-08-04 (later the same day): pi-02 physically moved onto the
  # battery outlets of the UPS it monitors — the bottom OR700, shared only
  # with the pfSense SG-1100 (~15 W combined, hours of runtime). Power and
  # data are aligned again, so the module's default powerValue 1 on the
  # local qnapups is correct and the brief secondary-of-pi-01
  # subscription from earlier that day is gone. This UPS is the house's
  # "survivor": router + wake orchestrator (see rack-wake below) outlive
  # any realistic outage.

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  networking.hostName = "pi-02";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  # See pi-01: nvmd's installer image enables NetworkManager, which races
  # networkd for the untagged link. networkd only.
  networking.networkmanager.enable = lib.mkForce false;

  systemd.network.netdevs."10-vlan10" = {
    netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
    vlanConfig.Id = 10;
  };
  # Untagged = VLAN50, secondary (no gateway, not required for online).
  systemd.network.networks."10-end0" = {
    matchConfig.Name = "end0";
    vlan = [ "vlan10" ];
    address = [ "203.0.113.132/23" ];
    networkConfig.DHCP = "no";
    linkConfig.RequiredForOnline = "no";
  };
  # Tagged VLAN10 = primary; IPv6 suffix is hex(132) = 0x84, v6 default
  # route via pfSense's RA.
  systemd.network.networks."20-vlan10" = {
    matchConfig.Name = "vlan10";
    address = [
      "192.0.2.132/23"
      "2001:db8:50:a::84/64"
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

  # mkForce: layered into nvmd's installer-image builder, which also sets
  # stateVersion (from the nixpkgs release) - ours wins.
  system.stateVersion = lib.mkForce "26.05";
}
