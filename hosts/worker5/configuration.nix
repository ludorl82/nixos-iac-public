## worker5: a CPU-only k3s worker — a NixOS libvirt VM, 4 vCPU / 4 GiB / 60 GiB,
## single-homed on VLAN10 (192.0.2.135). Recreated on 2026-10-08 on stella,
## at the owner's request, as the "one CPU worker per X11SRA" of the net-cfgs
## backlog. It has NO card: the GPU node it was from 2026-09-14 to 09-26
## (borrowing the guests' cards) is git history — 566f50e^ has the nvidia
## half and the reasons it lived in a VM.
##
## MOVABLE like worker3: host-model CPU, no hostdev, so `vm-move worker5 bob`
## (modules/vm-host.nix) carries it live between the X11SRA hosts. The drain
## of a gaming session does not concern it — it is its own node.
##
## Install: the installer ISO (packages.installer-worker5, static IP) in the
## domain's cdrom, then nixos-anywhere --flake .#worker5 onto /dev/vda, with
## the k3s join token placed at /etc/rancher/k3s/token out of band.
{ config, lib, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ../../modules/k3s-agent.nix ../../modules/private-ca.nix ];

  services.k3s.extraFlags = [
    "--node-ip=192.0.2.135"
  ];

  networking.hostName = "worker5";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      # IPv4 ONLY on this macvtap, like the arcade guests and win11. stella's
      # VLAN10 reflects the guest's own IPv6 NDP/DAD multicast
      # back to it, so the link-local address fails duplicate-address detection
      # in an endless loop, the link never leaves "configuring", and the static
      # IPv4 never commits. worker4 carries an IPv6 address happily because it
      # lives on vega, where this does not happen — do not copy it here.
      # (The hex(last-octet) convention would have made this ::87.)
      Address = [ "192.0.2.135/23" ];
      Gateway = "192.0.2.254";
      DNS = [ "192.0.2.254" ];
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
    # "~." routes every lookup at pfSense's Unbound; without it resolved only
    # consults it for the search domains and sends the rest to public
    # fallbacks, which cannot see the internal zone.
    domains = [ "lab.example" "example.com" "~." ];
    # No RequiredForOnline override: this is the only interface, so
    # systemd-networkd-wait-online must actually wait for it. Marking it
    # optional is what made worker4 fail wait-online on every boot.
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Guest agent: lets the host shut it down cleanly (virsh shutdown --mode agent).
  services.qemuGuest.enable = true;

  users.users.ludorl82 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  system.stateVersion = "26.05";
}
