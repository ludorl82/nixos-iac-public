## Headless installer for the vm-03 VM. VLAN10 has NO DHCP server, and
## the VM sits on VLAN10 via macvtap (untagged to the guest), so the
## installer pins a STATIC IP (vm-03's final address) on its single
## virtio NIC - can't rely on DHCP the way the physical-host installers
## do. Reachable at 192.0.2.135 over SSH the moment it boots; then
## nixos-anywhere --flake .#vm-03 installs the real system onto /dev/vda.
{ lib, ... }:
{
  networking.networkmanager.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Type = "ether";
      networkConfig = {
        Address = "192.0.2.135/23";
        Gateway = "192.0.2.254";
        DNS = "192.0.2.254";
        # IPv4 ONLY, and this is not a preference. On gaming-01's VLAN10 macvtap
        # the guest's own IPv6 NDP/DAD multicast is reflected back to it, so
        # the link-local address fails duplicate-address detection forever,
        # pins the link in "configuring", and the static IPv4 never commits —
        # the installer boots with NO address and nothing can reach it.
        # arcade1 hit this on 2026-08-17; vm-02's installer does not carry
        # the fix because it runs on srv-01, where the reflection does not
        # happen. Copying vm-02 verbatim is what cost us a boot here.
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
      };
      linkConfig.RequiredForOnline = "no";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
  ];
}
