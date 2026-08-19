## Headless-reachable x86_64 NixOS installer for srv-01.
##
## srv-01 has NO usable console - its discrete GPU won't output
## BIOS/console/text-mode video on any cable (VGA adapter OR native HDMI
## both stay blank; POST beeps confirm it powers up fine). So this
## installer image must come up on the network by itself so we can SSH in.
##
## Deliberately uses PLAIN DHCP on the untagged native VLAN (not the
## tagged VLAN10 the final system uses) - lowest-risk: no VLAN netdev to
## misconfigure, and we already know srv-01's NIC pulls a lease on the
## native VLAN (it grabbed 203.0.113.x during the earlier kexec). Find
## the lease by MAC 02:00:00:00:00:01 in Kea on router after boot.
##
## Once reachable, re-run nixos-anywhere against it (VARIANT_ID=installer
## image, so it skips kexec) WITH --generate-hardware-config this time,
## fixing the missing initrd storage modules that made the first install
## unbootable.
{ lib, ... }:
{
  networking.networkmanager.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # DHCP on ANY ethernet device (Type=ether), not a specific name - works
  # on physical hosts (eno1) and libvirt/virtio VMs (ens3/enp1s0) alike.
  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Type = "ether";
      networkConfig.DHCP = "yes";
      linkConfig.RequiredForOnline = "no";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
  ];
}
