## Headless installer ISO for arcade2's nixos-anywhere install — twin of
## arcade1's. The VM boots this from a libvirt <cdrom>, comes up on the pinned
## static VLAN10 address, and nixos-anywhere installs into /dev/vda over SSH.
## net0 is matched by the MAC libvirt assigns (02:00:00:00:00:01); net1
## (VLAN50, which has DHCP) is the fallback.
{ lib, ... }:
{
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  networking.networkmanager.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;

    networks."10-vlan10" = {
      matchConfig.MACAddress = "02:00:00:00:00:01";
      address = [ "192.0.2.142/23" ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig.DNS = "192.0.2.254";
      linkConfig.RequiredForOnline = "no";
    };

    networks."15-fallback-dhcp" = {
      matchConfig.Name = "en*";
      networkConfig.DHCP = "ipv4";
      linkConfig.RequiredForOnline = "no";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example fleet-deploy"
  ];
}
