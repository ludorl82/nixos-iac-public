## Headless installer for the console-vm console VM. VLAN10 has NO DHCP
## server, and the VM sits on VLAN10 via macvtap (untagged to the guest),
## so the installer pins a STATIC IP (console-vm's final address) on its
## single virtio NIC - can't rely on DHCP the way the physical-host
## installers do. Reachable at 192.0.2.136 over SSH the moment it boots;
## then nixos-anywhere --flake .#console-vm installs the real system onto
## /dev/vda.
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
        Address = "192.0.2.136/23";
        Gateway = "192.0.2.254";
        DNS = "192.0.2.254";
      };
      linkConfig.RequiredForOnline = "no";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example fleet-deploy"
  ];
}
