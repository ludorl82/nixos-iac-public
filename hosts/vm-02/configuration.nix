## vm-02: minimal NixOS base, running as a libvirt VM on srv-01
## (macvtap onto srv-01's vlan10). Same host/IP it had as the old
## k3s VM; k3s rejoin is a follow-up (cluster is cloud-01+gpu-01 now).
##
## The VM sits directly on VLAN10 via macvtap, so the guest sees untagged
## traffic - no VLAN netdev needed in the guest, just a static IP on its
## single virtio NIC, matched by the VM's fixed MAC (set in the libvirt
## domain) so it's independent of the guest's NIC name.
##
## hardware-configuration.nix (virtio initrd modules) is generated on the
## booted installer VM during the nixos-anywhere run, same as the physical
## hosts - omitting it makes the install unbootable.
{ ... }:
{
  imports = [ ./hardware-configuration.nix ../../modules/k3s-agent.nix ../../modules/private-ca.nix ];
  services.k3s.extraFlags = [ "--node-ip=192.0.2.134" ];

  networking.hostName = "vm-02";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      # IPv6 follows the hex(last-octet) convention (134 -> 0x86). NOTE: for
      # a macvtap guest this address is only reachable INBOUND if the host's
      # <interface> carries trustGuestRxFilters='yes' AND the VM has been
      # fully stopped/started (not just rebooted) since that was set -
      # otherwise the macvtap filter never learns the new v6 multicast/MAC
      # groups and NDP for it is silently dropped.
      Address = [
        "192.0.2.134/23"
        "2001:db8:50:a::86/64"
      ];
      Gateway = "192.0.2.254";
      DNS = [ "192.0.2.254" ];
      IPv6AcceptRA = true;
    };
    # "~." routes *every* lookup at pfSense's Unbound. Without it
    # systemd-resolved only consults 192.0.2.254 for the search domains
    # and sends everything else to its built-in public fallbacks, which
    # can't see the internal zone - `curl https://kuma.lab.example/` failed
    # with "Could not resolve host" until this was added. Same line
    # pi-01/pi-02/vm-03 already carry.
    domains = [ "lab.example" "example.com" "~." ];
    # NB: no RequiredForOnline = "no" here. This is vm-02's *only*
    # interface, so marking it optional left systemd-networkd-wait-online
    # with nothing to wait for - it timed out and failed on every boot,
    # which also made `nixos-rebuild switch` exit 4 even though activation
    # had succeeded. On vm-03 that setting belongs only on the secondary
    # VLAN50 link.
  };
  # Untagged VLAN50, via a SECOND macvtap interface on srv-01's `eno1`
  # (VLAN50 is the untagged/native VLAN on that trunk; `vlan10` is the tagged
  # sub-interface the primary NIC rides on). Same shape vm-01 used on gpu-01.
  # Secondary: address only, deliberately no gateway, so the default route
  # stays exclusively on VLAN10. RequiredForOnline=no is correct HERE - it is
  # wrong on 10-lan above, which is the link wait-online must actually wait
  # for.
  systemd.network.networks."20-vlan50" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig.Address = "203.0.113.134/23";
    linkConfig.RequiredForOnline = "no";
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.ludorl82 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  system.stateVersion = "26.05";
}
