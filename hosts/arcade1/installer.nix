## Headless installer ISO for arcade1's nixos-anywhere install.
##
## WHY AN ISO AND NOT KEXEC: arcade1 is a fresh, empty libvirt VM — there is
## no running Linux to kexec from, exactly like gaming-01 was. The VM boots this
## ISO from a libvirt <cdrom> (see hosts/arcade1/libvirt-domain.xml), comes up
## with a known static address, and nixos-anywhere installs into /dev/vda over
## SSH from gpu-01.
##
## NETWORK: the VM's net0 is a macvtap onto gaming-01's `vlan10`, so the guest
## sees UNTAGGED VLAN10 — a plain static address on the NIC, no VLAN netdev.
## VLAN10 has no DHCP, so the installer pins 192.0.2.141 the way the physical
## installers pin theirs. The NIC is matched by the MAC libvirt assigns
## (02:00:00:00:00:01) rather than a name, since a VM's NIC naming is not
## guaranteed. net1 (VLAN50, which DOES have DHCP) is the fallback path.
{ lib, ... }:
{
  # Serial console on the guest's first UART, reachable via `virsh console
  # arcade1` on gaming-01 — a second way in if the static address is wrong.
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  networking.networkmanager.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;

    # Intended path: net0 (VLAN10) at the pinned static address.
    networks."10-vlan10" = {
      matchConfig.MACAddress = "02:00:00:00:00:01";
      address = [ "192.0.2.141/23" ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig.DNS = "192.0.2.254";
      linkConfig.RequiredForOnline = "no";
    };

    # Fallback: any other NIC (net1 on VLAN50) takes DHCP — find the lease in
    # Kea on pfSense if the static path does not come up.
    networks."15-fallback-dhcp" = {
      matchConfig.Name = "en*";
      networkConfig.DHCP = "ipv4";
      linkConfig.RequiredForOnline = "no";
    };
  };

  # The laptop key, the nixos-anywhere key, and gpu-01's own interactive key —
  # same set gaming-01's installer carries, for the same reason: gpu-01 is what
  # actually drives the install and gets a shell on the booted installer.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example fleet-deploy"
  ];
}
