## "docker" — the ex-console-vm Pi 4 (2 GB), reborn 2026-08-05 as the fleet's
## private container registry (net-cfgs/backlog.md: registry item). The
## jumphost role moved to pi-02 the same week; this box keeps exactly one
## job. Deliberately OUTSIDE k3s and OUTSIDE comin: 2 GB cannot eval the
## flake (pi-01's SIGBUS lesson at 4 GB), so deploys are pushed from gpu-01:
##   nixos-rebuild switch --flake .#docker --target-host ludorl82@192.0.2.35 --use-remote-sudo
##
## Registry blobs live on a QNAP NFS share (`docker-registry`, manual
## Control Panel creation — new shares default read-only+all_squash, the
## /k8s trap). Guardrails per the 2026-08-03 D-state lesson: automount +
## nofail + soft so a vanished NAS degrades the registry instead of
## wedging the Pi, and the service orders after the mount. A registry is a
## rebuildable cache: no backups, worst case is re-pushing images.
##
## Single-homed on VLAN10: 192.0.2.35 / ::23 (hex convention), untagged
## VLAN50 carries a secondary address only. NIC matches end0 OR eth0 —
## mainline + systemd naming usually lands on end0; both matched until the
## first boot confirms.
{ config, pkgs, lib, ... }:
{
  # MAINLINE aarch64 NixOS, not the nvmd vendor-kernel stack: the Pi 4 is
  # fully supported upstream (unlike the Pi 5), the generic kernel is
  # prebuilt in cache.nixos.org, and a headless registry needs none of the
  # vendor kernel's GPU/camera extras. First image build: minutes, not the
  # 2-4 h emulated vendor-kernel compile this replaced.
  imports = [ ../../modules/private-ca.nix ];

  networking.hostName = "docker";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.networkmanager.enable = lib.mkForce false;

  # 2 GB Pi: zram is the only swap, same rationale as the Pi 5 workers.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  systemd.network.netdevs."10-vlan10" = {
    netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
    vlanConfig.Id = 10;
  };
  systemd.network.networks."10-phys" = {
    matchConfig.Name = "end0 eth0";
    vlan = [ "vlan10" ];
    address = [ "203.0.113.35/23" ];
    networkConfig.DHCP = "no";
    linkConfig.RequiredForOnline = "no";
  };
  systemd.network.networks."20-vlan10" = {
    matchConfig.Name = "vlan10";
    address = [
      "192.0.2.35/23"
      "2001:db8:50:a::23/64"
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
      # gpu-01 pushes this host's deploys (no comin at 2 GB) — weekly flake bumps too
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example fleet-deploy"
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # --- the one job: registry:2 ------------------------------------------
  services.dockerRegistry = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = 5000;
    storagePath = "/mnt/docker-registry";
    enableGarbageCollect = true;
    # TLS: private-CA leaf (pki.example.com, expires 2036). Cert+key are
    # out-of-band at /var/lib/registry-tls (owner docker-registry, key 600);
    # source files live in the jumphost's Certificats/pki/docker.lab.example.
    # Clients need no config: the fleet trusts the CA via private-ca.nix.
    extraConfig.http.tls = {
      certificate = "/var/lib/registry-tls/docker.lab.example.crt";
      key = "/var/lib/registry-tls/docker.lab.example.key";
    };
  };
  fileSystems."/mnt/docker-registry" = {
    device = "192.0.2.65:/docker-registry";
    fsType = "nfs";
    options = [
      "nfsvers=4.1"
      "x-systemd.automount"
      "noauto"
      "nofail"
      "soft"
      "timeo=100"
      "x-systemd.idle-timeout=600"
    ];
  };
  systemd.services.docker-registry.unitConfig.RequiresMountsFor =
    [ "/mnt/docker-registry" ];
  networking.firewall.allowedTCPPorts = [ 5000 ];

  system.stateVersion = lib.mkForce "26.05";
}
