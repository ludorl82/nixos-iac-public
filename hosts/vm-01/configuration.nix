## vm-01: minimal NixOS base, a libvirt VM on gpu-01 (macvtap onto gpu-01's
## vlan10) - same shape as vm-02-on-srv-01. vm-01 was previously a
## k3s VM on gpu-01 (retired 2026-07-24); this recreates it on the NixOS gpu-01.
## Guest sits directly on VLAN10 via macvtap (untagged to the guest), so
## just a static IP on the single virtio NIC, matched by the VM's fixed
## MAC (set in the libvirt domain). Static 192.0.2.133, its old address.
##
## hardware-configuration.nix (virtio initrd modules) is generated on the
## booted installer VM during nixos-anywhere; the copied placeholder from
## vm-02 is correct for an identical virtio VM.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/k3s-agent.nix
    ../../modules/private-ca.nix
  ];
  services.k3s.extraFlags = [ "--node-ip=192.0.2.133" ];

  networking.hostName = "vm-01";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      # IPv6 follows the hex(last-octet) convention (133 -> 0x85). Reachable
      # inbound only because this VM's macvtap <interface> carries
      # trustGuestRxFilters='yes' AND model virtio - see
      # hosts/vm-01/libvirt-domain.xml.
      Address = [
        "192.0.2.133/23"
        "2001:db8:50:a::85/64"
      ];
      Gateway = "192.0.2.254";
      DNS = "192.0.2.254";
      IPv6AcceptRA = true;
    };
    # NB: no RequiredForOnline=no here - it's the only NIC, and setting that
    # makes systemd-networkd-wait-online fail (vm-02 lesson). Also add the
    # "~." domain so systemd-resolved routes all lookups at pfSense (vm-02
    # lesson - otherwise internal names fall to public fallback DNS).
    domains = [ "lab.example" "example.com" "~." ];
  };
  # Untagged VLAN50, via a SECOND macvtap interface on gpu-01's `eno2` (VLAN50
  # is the untagged/native VLAN on that trunk; `vlan10` is the tagged
  # sub-interface the primary NIC rides on). Same shape as vm-02 on
  # srv-01. Secondary: address only, deliberately no gateway, so the
  # default route stays exclusively on VLAN10. RequiredForOnline=no is
  # correct HERE - it is wrong on 10-lan above, which is the link
  # wait-online must actually wait for (the vm-02 lesson noted there).
  systemd.network.networks."20-vlan50" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig.Address = "203.0.113.133/23";
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
