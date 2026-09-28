## Minimal, networked, SSH-reachable base for srv-01's NixOS
## conversion (2026-07-24). The md RAID5 media array + data-vg came back
## on 2026-09-16 (see the "Ubuntu-era media RAID" block below), and the
## two NTFS media disks and backup-vg the same day. Still deliberately
## NOT covered: MakeMKV + Blu-ray ripping tooling, and the alloy log-shipping
## container that ran under docker on the old Ubuntu install - a
## follow-up phase, tracked separately, not silently dropped.
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
  # Routage par source pour la patte VLAN50 : voir modules/dual-homed-routing.nix.
  labo.dualHomed = {
    enable = true;
    octet = 97;
    vlan10Network = "30-mvhost";
    vlan50Network = "25-mvhost50";
  };
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
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
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

  ## --- Ubuntu-era media RAID (adopted 2026-09-16) -----------------------
  ##
  ## Found dormant while hunting for lost voice clips: the old install's
  ## RAID5 `srv-01.lab.example:0` (sdg+sdh+sdj, 3x2.7T) is one PV of
  ## `data-vg`, together with sde+sdf which serve as a dm-cache
  ## (writethrough) in front of the single LV `media` (5.46T ext4: 1.4T of
  ## 3D Blu-ray ISOs + TV3D). Last written 2026-07-24, the eve of the
  ## reimage; nothing here has touched it since, and the user wants it kept.
  ##
  ## Three things the stock config lacked, each found by trying to read it:
  ##  - no mdadm in the closure (`boot.swraid`), so the array never assembled;
  ##  - no dm-cache module loaded ("cache target support missing from
  ##    kernel?"), so lvm refused to activate the cached LV;
  ##  - no cache_check binary, which lvm only warns about - `boot.thin` is
  ##    the NixOS knob that wires thin-provisioning-tools into lvm.conf for
  ##    both thin AND cache LVs, hence its otherwise odd presence here.
  ## Assembly is by array UUID, not by /dev/sdX: the letters shuffle at boot.
  ## `nofail`: a media shelf must never keep the k3s node from booting.
  boot.swraid.enable = true;
  boot.swraid.mdadmConf = ''
    ARRAY /dev/md/srv-01:0 metadata=1.2 UUID=df21479c:50d2bc25:fe2369f2:4ca93dd0
    MAILADDR root
  '';
  boot.kernelModules = [ "dm-cache" "dm-cache-smq" ];
  services.lvm.boot.thin.enable = true;
  fileSystems."/mnt/media" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=90s" ];
  };

  ## The two 7.3 TB NTFS disks from the same era, labelled ISO1 (sda1:
  ## `tvs`, 3.7 TB) and ISO2 (sdc2: `mvs` 2.5 TB + `tvs` 3.8 TB) - the old
  ## Plex library, ripped on Windows back in the day, which is why they are
  ## NTFS. Kernel `ntfs3` driver (no ntfs-3g/FUSE): read-write, and it is
  ## what worked when they were first read back. Ownership is mapped to
  ## ludorl82 since NTFS carries no POSIX ids; same `nofail` rule as above.
  fileSystems."/mnt/iso1" = {
    device = "/dev/disk/by-uuid/1EBAC174BAC148CB";
    fsType = "ntfs3";
    options = [ "nofail" "uid=1000" "gid=100" "umask=002" "x-systemd.device-timeout=30s" ];
  };
  fileSystems."/mnt/iso2" = {
    device = "/dev/disk/by-uuid/1698E31098E2ECE5";
    fsType = "ntfs3";
    options = [ "nofail" "uid=1000" "gid=100" "umask=002" "x-systemd.device-timeout=30s" ];
  };

  ## backup-vg/backup-lv, 128 GB ext4 on the sdb2 SSD: the Blu-ray scratch
  ## space (`2d_temp`, `3d_temp`, `BD3D2MK3D`) - the same layout gpu-01 and
  ## gpu-02 carry on their own SATA SSDs. Plain LVM, activated by the
  ## default lvm udev rules; nothing exotic, unlike data-vg above.
  fileSystems."/mnt/backup" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=30s" ];
  };

  system.stateVersion = "26.05";
}
