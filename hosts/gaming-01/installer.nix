## Headless installer ISO for gaming-01's NixOS conversion.
##
## WHY AN ISO AND NOT KEXEC: gpu-01 was converted in place with
## `nixos-anywhere --kexec` (packages.kexec-gpu-01), but that path needs the
## target to already be running Linux. gaming-01 runs Windows 11 + Hyper-V,
## so there is nothing to kexec *from* — the only remote path is booting
## this ISO through the X11SRA-RF's virtual media (BMC 192.0.2.6) and
## installing from there. Secure Boot must be OFF for it to boot at all:
## Windows 11 requires Secure Boot, NixOS ships no signed shim, and the
## vm-03 conversion already proved Secure Boot blocks this cold.
##
## NETWORK, AND WHY IT IS BELT-AND-BRACES: VLAN 10 has no DHCP server, so
## the VLAN 10 address has to be pinned the way hosts/vm-02/installer.nix
## pins vm-02's. But gaming-01's interface *names* are unverified — gpu-01 is
## the same board (X11SRA-RF) and uses eno2 with eno1 unused, so eno2 is
## the informed guess, not a fact. If the guess is wrong the tagged config
## lands on a NIC that isn't the uplink and the installer is unreachable on
## VLAN 10.
##
## So there are deliberately two ways in:
##   1. eno2 → vlan10 → static 192.0.2.140 (the intended path)
##   2. every OTHER ethernet NIC → DHCP on the untagged VLAN 50, which
##      does have a DHCP server (203.0.113.10–.250)
## systemd-networkd applies the first matching .network in lexical order,
## so "10-uplink" claims eno2 and "15-fallback-dhcp" only ever picks up the
## interfaces 10-uplink did not match. If the uplink turns out to be eno1,
## path 2 still gives a reachable installer — find its lease in Kea on
## pfSense. Last resort is the iKVM console, which is always available.
##
## No gateway is needed on the VLAN 50 fallback: gpu-01 sits at
## 203.0.113.129/23 and gaming-01 at .140/23, so the install source is
## on-link.
{ lib, ... }:
{
  # Put a kernel console + getty on the BMC's Serial-over-LAN port so the
  # installer is drivable over `ipmitool sol activate`, not just SSH. On the
  # X11SRA-RF the SOL payload maps to ttyS1 (COM2); without this the getty
  # lands on a port the BMC doesn't bridge and SOL shows nothing (observed
  # 2026-08-17 — the first installer boot networked fine but SOL was silent).
  boot.kernelParams = [ "console=tty0" "console=ttyS1,115200n8" ];

  networking.networkmanager.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;

    netdevs."10-vlan10" = {
      netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
      vlanConfig.Id = 10;
    };

    # Intended uplink: trunk with VLAN 10 tagged, untagged native VLAN 50.
    networks."10-uplink" = {
      matchConfig.Name = "eno2";
      vlan = [ "vlan10" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };

    networks."20-vlan10" = {
      matchConfig.Name = "vlan10";
      address = [ "192.0.2.140/23" ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig.DNS = "192.0.2.254";
      linkConfig.RequiredForOnline = "no";
    };

    # Fallback path — see header. Only matches NICs 10-uplink did not.
    networks."15-fallback-dhcp" = {
      matchConfig.Name = "en*";
      networkConfig.DHCP = "ipv4";
      linkConfig.RequiredForOnline = "no";
    };
  };

  # The laptop, the key gpu-01 drives nixos-anywhere with, and — added
  # 2026-08-17 — gpu-01's own interactive key. The first two are unreachable
  # when driving the installer by hand from a Claude session on gpu-01 (the
  # laptop is off-network, the nixos-anywhere key is ephemeral per deploy),
  # so gpu-01's persistent id_ed25519 is what actually gets a shell on a booted
  # installer over `ssh root@192.0.2.140` from gpu-01.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example fleet-deploy"
  ];
}
