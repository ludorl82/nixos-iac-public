## Real per-host config for pi-02 (Pi5), built into a bootable nvmd
## nixos-raspberrypi image via lib.nixosInstaller (same as pi-01). The
## installer builder provides the FIRMWARE/NIXOS_SD fileSystems, so this
## config doesn't declare them. Networked + SSH, and a k3s agent via
## modules/k3s-agent.nix (rejoined 2026-07-24). pi-02's SD slot is
## broken, so USB is its only boot path - proven working with the nvmd
## kernel-boot image.
##
## HYBRID BOOT since 2026-08-07 - firmware+kernel on the USB stick, root on
## NVMe. Direct NVMe *boot* is broken upstream (nvmd/nixos-raspberrypi #117,
## Pi 5 firmware fatal error 45), so the buggy path is never exercised: the
## firmware still reads config.txt/kernel/initrd from the USB FIRMWARE
## partition, and only the root filesystem moved. The lever is purely the
## ext4 label - cmdline.txt says `root=fstab` and the generated fstab says
## `/dev/disk/by-label/NIXOS_SD`, so moving NIXOS_SD from the USB partition
## (/dev/sda2, relabelled NIXOS_USB) onto /dev/nvme0n1p1 is the whole
## cutover. Nothing in this file had to change for it, which is exactly why
## this comment exists. Two consequences worth knowing:
##   - The USB partition is still a complete, bootable system. Rollback is
##     `e2label /dev/sda2 NIXOS_SD` (clearing the NVMe label) from any Linux
##     box - the Pi cannot do it from its own initrd.
##   - Do NOT let both partitions carry NIXOS_SD at once; the initrd would
##     pick one at random. Always move the label, never copy it.
## No initrd module work was needed: the vendor kernel has CONFIG_BLK_DEV_NVME
## and CONFIG_PCIE_BRCMSTB built in (=y, not modules), and the Pi 5 brings the
## PCIe port up without an explicit dtparam.
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
  ]) ++ [ ../../modules/k3s-agent.nix ../../modules/private-ca.nix ../../modules/ups-cp-1.nix ../../modules/rack-wake.nix ../../modules/house-heartbeat.nix ../../modules/jumphost.nix ../../modules/console-container.nix ../../modules/ha-backup.nix ];

  # Emergency console only, since the jumphost/console split cutover
  # (2026-08-07): the real console is the console-vm VM on gpu-01. Image stays
  # resident, unit stays declared, `systemctl start docker-console`
  # brings it up by hand — pi-02 is the survivor-island host, so this
  # is the shell that outlives a house power event. Note the switch does
  # NOT stop an already-running container (wantedBy only affects boot);
  # the cutover stopped it manually.
  homelab.console.autoStart = false;
  services.k3s.extraFlags = [ "--node-ip=192.0.2.132" ];

  # See pi-01 for the full reasoning: the Pi builds come from
  # nixos-raspberrypi's pinned nixpkgs (25.11), which stops at k3s_1_34 and
  # so cannot supply the fleet's version, hence k3s alone comes from the
  # top-level nixpkgs. Only this package is overridden -- the vendor kernel
  # and Pi firmware must keep coming from the pinned set. Overrides the
  # mkDefault in modules/k3s-agent.nix; keep the version in step with it.
  # 2026-08-09: k3s_1_36 -> the shared upstream-binary expression (nixpkgs
  # still packages 1.36.2 there, upstream stable is 1.36.3). Same file the
  # server and every other agent use, still built against the top-level
  # nixpkgs instance rather than the Pi's pinned one.
  services.k3s.package =
    nixpkgs.legacyPackages.aarch64-linux.callPackage
      ../../modules/k3s-upstream.nix { };

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

  # --- private container registry (moved here from the `docker` Pi, 2026-08-17)
  #
  # It lived on a dedicated Raspberry Pi 4 whose storage was an NFS share on
  # the QNAP. On 2026-08-12 04:23 that share stopped answering ("nfs: server
  # 192.0.2.65 not responding"), the client never recovered, and the
  # registry process sat unkillable in D state for five days serving 503 to
  # everything. Nobody noticed, because nothing monitored it. It also took
  # the 2026-08-16 weekly-updates run down with it: `nixos-rebuild switch`
  # against that Pi hung at "activating the configuration" and Cronicle
  # killed the job at its 3-hour cap, so that week's appliance updates never
  # ran at all.
  #
  # The whole registry existed to hand ONE image to console-vm — the console
  # container — pulled once per digest change by a manual rebuild. A Pi, an
  # NFS dependency, a TLS cert and one more fleet host to patch, for that.
  #
  # Here instead, storage is pi-02's local NVMe: no network filesystem in
  # the path at all. The name `docker.lab.example` and its private-CA cert are
  # unchanged, so clients keep working untouched — only the DNS record moves.
  # Once pi-01 also has NVMe, this is the half that gets replicated.
  services.dockerRegistry = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = 5000;
    # local NVMe — deliberately NOT an NFS path; see above
    storagePath = "/var/lib/docker-registry";
    enableGarbageCollect = true;
    # Same private-CA leaf as before (pki.example.com, expires 2036), so
    # the cert still matches the name. Cert+key are out-of-band at
    # /var/lib/registry-tls (owner docker-registry, key 600), copied off the
    # Pi during the move. Clients need no config: the fleet trusts the CA via
    # modules/private-ca.nix.
    extraConfig.http.tls = {
      certificate = "/var/lib/registry-tls/docker.lab.example.crt";
      key = "/var/lib/registry-tls/docker.lab.example.key";
    };
  };
  networking.firewall.allowedTCPPorts = [ 5000 ];

  # mkForce: layered into nvmd's installer-image builder, which also sets
  # stateVersion (from the nixpkgs release) - ours wins.
  system.stateVersion = lib.mkForce "26.05";
}
