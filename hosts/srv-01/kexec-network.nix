## Custom network config for the ephemeral kexec installer stage of
## srv-01's nixos-anywhere install.
##
## WHY THIS EXISTS: the stock nixos-images kexec installer preserves the
## source machine's network by running restore_routes.py, which only
## re-applies addresses/routes matched by MAC and NEVER recreates VLAN
## netdevs. srv-01's uplink is a trunk with VLAN10 tagged (eno1.10,
## static 192.0.2.97) over an untagged native VLAN50. Because eno1.10
## shares eno1's MAC, the restore writes a `00-*.network` (sorts first,
## matches by MAC, DHCP=yes) that slaps the static IP onto the *untagged*
## eno1 and also grabs a VLAN50 DHCP lease (203.0.113.x) - so the
## installer comes up on a different network/address than the running
## system, breaking nixos-anywhere's single fixed --target-host. See the
## vm-02/srv-01 session notes.
##
## FIX: disable restore-network and pin the exact VLAN10 static config, so
## the installer comes up at 192.0.2.97 - identical before/after kexec.
## This is the reusable pattern for converting any VLAN-tagged host.
{ lib, ... }:
{
  systemd.services.restore-network.enable = lib.mkForce false;

  systemd.network = {
    enable = true;
    netdevs."10-vlan10" = {
      netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
      vlanConfig.Id = 10;
    };
    networks."10-eno1" = {
      matchConfig.Name = "eno1";
      vlan = [ "vlan10" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    networks."20-vlan10" = {
      matchConfig.Name = "vlan10";
      address = [ "192.0.2.97/23" ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig.DNS = "192.0.2.254";
    };
  };
}
