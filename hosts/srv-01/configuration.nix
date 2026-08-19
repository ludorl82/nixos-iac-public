## Minimal, networked, SSH-reachable base for srv-01's NixOS
## conversion (2026-07-24). Deliberately does NOT yet cover: the
## md0 RAID5 media array / data-vg / backup-vg mounts, MakeMKV +
## Blu-ray ripping tooling, or the alloy log-shipping container that
## ran under docker on the old Ubuntu install - those are a follow-up
## phase, tracked separately, not silently dropped.
##
## hardware-configuration.nix (imported below) carries the initrd
## storage-controller modules (ahci/sd_mod/etc.) - omitting those the
## first time made the install unbootable (initrd couldn't mount root).
##
## Networking uses systemd-networkd with the exact VLAN10 config already
## proven to reach 192.0.2.97 in the kexec installer, rather than the
## scripted-networking form used in the first (never-booted, untested)
## attempt - lower risk of coming up unreachable on a box we can't see
## the console of.
{ pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ../../modules/k3s-agent.nix ../../modules/private-ca.nix ../../modules/ups-client.nix ];
  services.k3s.extraFlags = [ "--node-ip=192.0.2.97" ];

  networking.hostName = "srv-01";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    netdevs."10-vlan10" = {
      netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
      vlanConfig.Id = 10;
    };
    ## macvtap host<->guest fix, mirroring gpu-01 (which hosts vm-01 the same
    ## way this host hosts vm-02). A macvtap guest CANNOT talk to the host
    ## stack on its own parent interface - that's a kernel-level property of
    ## macvtap, not a firewall or routing problem, so no rule fixes it. The
    ## workaround is to move the host's own address onto a MACVLAN over the
    ## same parent, which joins the same L2 domain the guest is on.
    ##
    ## Symptom without this: vm-02 cannot ping srv-01 (either address),
    ## srv-01 cannot ping vm-02, and - the part that actually hurts -
    ## flannel traffic between the two k3s nodes is silently dropped, so pods
    ## on srv-01 (cronicle, traefik svclb, metrics-server) can't reach
    ## pods on vm-02.
    ##
    ## Both VLANs need it, because vm-02 has a macvtap on EACH parent:
    ## net0 on `vlan10`, net1 on the untagged `eno1`. gpu-01 originally only got
    ## the vlan10 half, which left vm-01 unable to reach gpu-01 on VLAN50.
    netdevs."15-mvhost" = {
      netdevConfig = { Name = "mvhost"; Kind = "macvlan"; };
      macvlanConfig.Mode = "bridge";
    };
    netdevs."16-mvhost50" = {
      netdevConfig = { Name = "mvhost50"; Kind = "macvlan"; };
      macvlanConfig.Mode = "bridge";
    };
    # Untagged = VLAN50. Parents both the tagged vlan10 netdev and the
    # VLAN50 macvlan; carries no address itself (it moved to mvhost50).
    networks."10-eno1" = {
      matchConfig.Name = "eno1";
      vlan = [ "vlan10" ];
      macvlan = [ "mvhost50" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # vlan10 now just parents the macvlan + brings the link up - no IP here.
    networks."20-vlan10" = {
      matchConfig.Name = "vlan10";
      macvlan = [ "mvhost" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # srv-01's VLAN50 address, on the macvlan. Secondary: address only,
    # deliberately NO gateway, so the default route stays exclusively on
    # VLAN10 - that's also what keeps cloud-01 reachable over the WireGuard
    # tunnel (a VLAN50 default route would send tunnel replies out the
    # wrong interface).
    networks."25-mvhost50" = {
      matchConfig.Name = "mvhost50";
      address = [ "203.0.113.97/23" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # srv-01's actual VLAN10 address, on the macvlan. The only interface
    # with a gateway. IPv6 follows the hex(last-octet) convention (97 ->
    # 0x61); the v6 default route comes from pfSense's RA.
    networks."30-mvhost" = {
      matchConfig.Name = "mvhost";
      address = [
        "192.0.2.97/23"
        "2001:db8:50:a::61/64"
      ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig = { DHCP = "no"; DNS = "192.0.2.254"; IPv6AcceptRA = true; };
      # "~." makes pfSense's Unbound the resolver for *everything*. Without
      # it systemd-resolved falls back to its built-in public servers
      # (1.1.1.1 & co.), which cannot resolve the internal lab.example zone:
      # public names work, every homelab name is NXDOMAIN. Same trap as
      # vm-03 and gpu-02.
      domains = [ "lab.example" "example.com" "~." ];
    };
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.ludorl82 = {
    isNormalUser = true;
    extraGroups = [ "wheel" "libvirtd" "kvm" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  # libvirt/qemu-kvm host - srv-01 hosts the vm-02 NixOS VM (macvtap
  # on the vlan10 interface), same role it had under Ubuntu. virt-manager
  # provides the virt-install CLI for defining domains imperatively (virsh
  # comes from libvirtd itself; OVMF/UEFI firmware ships by default now).
  virtualisation.libvirtd.enable = true;
  # On host power-off, gracefully ACPI-shut-down guests (vm-02), and cold-start
  # them on boot. vm-02 is a k3s node: a clean shutdown + cold rejoin is
  # correct — suspend/resume would leave it with a stale clock, dead API-server
  # watches and etcd-lease churn. Its HA "off" is a graceful `power soft` on
  # srv-01's BMC, so this hook runs. See the fleet HA power-switch work.
  virtualisation.libvirtd.onShutdown = "shutdown";
  virtualisation.libvirtd.onBoot = "start";
  environment.systemPackages = with pkgs; [ virt-manager ];

  system.stateVersion = "26.05";
}
