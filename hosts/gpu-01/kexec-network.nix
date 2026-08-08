## Custom network config for the ephemeral kexec installer stage of
## gpu-01's nixos-anywhere install.
##
## WHY THIS EXISTS: the stock nixos-images kexec installer preserves the
## source machine's network by running restore_routes.py, which only
## re-applies addresses/routes matched by MAC and NEVER recreates VLAN
## netdevs. gpu-01's uplink is a trunk with VLAN10 tagged (eno2.10,
## static 192.0.2.129) over an untagged native VLAN50. Because eno2.10
## shares eno2's MAC, the restore writes a `00-*.network` (sorts first,
## matches by MAC, DHCP=yes) that slaps the static IP onto the *untagged*
## eno2 and also grabs a VLAN50 DHCP lease (203.0.113.x) - so the
## installer comes up on a different network/address than the running
## system, breaking nixos-anywhere's single fixed --target-host. See the
## vm-02/gpu-01 session notes.
##
## FIX: disable restore-network and pin the exact VLAN10 static config, so
## the installer comes up at 192.0.2.129 - identical before/after kexec.
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
    networks."10-eno2" = {
      matchConfig.Name = "eno2";
      vlan = [ "vlan10" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    networks."20-vlan10" = {
      matchConfig.Name = "vlan10";
      address = [ "192.0.2.129/23" ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig.DNS = "192.0.2.254";
    };
  };
}
