## arcade2: the second gaming VM — a NixOS libvirt guest on `gaming-01`, twin of
## arcade1, with the GTX 960 passed through (gaming-01 0000:17:00.0 10de:1401 +
## its audio fn 0000:17:00.1 10de:0fba, IOMMU group 7, vfio-bound by gaming-01's
## `vfio-pci.ids`; the <hostdev>s are in hosts/arcade2/libvirt-domain.xml).
## Created 2026-08-17 GPU-less; an RTX 3050 was installed and enabled
## 2026-08-22 and held this slot until 2026-09-17, when the cards were re-dealt
## — that 6GB GA107 went to arcade1 and this guest took the GM206, so gaming-01's
## host could keep the 8GB GA106 for k3s. The card change drags the DRIVER
## BRANCH with it: Maxwell is legacy, see the graphics block below.
##
## `gpu` below gates the nvidia driver + 32-bit GL + videoDrivers, so the VM
## can be run GPU-less again (emulated QXL only) by flipping it to false and
## dropping the <hostdev>s — nvidia without a card just makes services fail.
##
## Everything else mirrors arcade1: Plasma 6 auto-login (ludorl82), Steam + Remote
## Play, never lock/sleep, dual-homed VLAN10 .142 / VLAN50 .142, MAC-matched.
{ config, lib, pkgs, ... }:
let
  # true = the GTX 960 is passed through (see header). false = emulated
  # display only, no nvidia.
  gpu = true;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/private-ca.nix
    ../../modules/arcade-desktop.nix
  ];

  # Gaming guest: on only while someone is playing.
  labo.onDemand = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nixpkgs.config.allowUnfree = true;

  networking.hostName = "arcade2";
  networking.useNetworkd = true;
  # A desktop session turns NetworkManager on by default and it then FIGHTS networkd:
  # it DHCPs enp2s0 (stray Kea lease + a second default route) and keeps
  # re-activating "Wired connection 1" on enp1s0, which wipes the static
  # VLAN10 address (arcade1 lost 192.0.2.141 on 2026-08-22 — VNC, ping and
  # Steam all unreachable on the fleet side). networkd owns the NICs; NM off.
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = false;

  # net0 — VLAN10, primary, default route. hex(142) = 0x8e.
  systemd.network.networks."10-vlan10" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      Address = [ "192.0.2.142/23" ];   # IPv4 ONLY — see the IPv6 note
      Gateway = "192.0.2.254";
      DNS = [ "192.0.2.254" ];
      DHCP = "no";
      # IPv4-only: gaming-01's VLAN10 macvtap reflects the guest's own IPv6
      # NDP/DAD, looping the IPv6 link-local address and pinning the link in
      # "configuring" so the static IPv4 never commits. Cured by disabling IPv6
      # on this link. Confirmed the hard way on arcade1 (2026-08-17).
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
    domains = [ "lab.example" "example.com" "~." ];
    linkConfig.RequiredForOnline = "routable";
    # Source-based policy routing (added 2026-08-22): a reply sourced from the
    # VLAN10 address must leave via VLAN10/pfSense even when the peer sits on
    # the directly-connected VLAN50 subnet. Without this a VLAN50 Steam client
    # that resolved arcade2.lab.example to the VLAN10 address got its replies
    # straight out of enp2s0 (asymmetric: pfSense never saw the return leg and
    # dropped the state). Table 10 = the VLAN10 view of the world; the rule
    # picks it by source address. The main table keeps its single default route.
    routes = [
      { Destination = "192.0.2.0/23"; Table = 10; }
      { Gateway = "192.0.2.254"; Table = 10; }
    ];
    routingPolicyRules = [
      { From = "192.0.2.142/32"; Table = 10; Priority = 100; }
    ];
  };

  # net1 (VLAN50) was REMOVED 2026-08-24. Steam Remote Play cannot cope with a
  # multi-homed host: it advertised every local address, the client locked onto
  # the VLAN10 candidate for its UDP video channel, and the reply was
  # source-selected as the VLAN50 address -- a peer the client never contacted,
  # so it discarded every frame and the session died the instant video started.
  # Neither forcing a fallback (the client re-sent 200 packets to VLAN10 and
  # never tried VLAN50) nor SNATing the reply source fixed it; Valve has no
  # interface selector (ValveSoftware/steam-for-linux#7131) and the standing
  # upstream advice for this bug is to leave exactly one interface active.
  # These VMs are now single-homed on VLAN10; VLAN50 clients reach them through
  # pfSense, which they already did for the control channel. The table-10
  # policy routing above is vestigial with one NIC but harmless, and is kept so
  # the pattern survives if a second leg is ever reinstated.
  # NOTE: the VLAN50 address is no longer a recovery path -- use the qemu guest
  # agent from gaming-01 (see [[gaming-01-gaming-vms-and-k3s]]).

  networking.search = [ "lab.example" "example.com" ];

  services.qemuGuest.enable = true;

  # --- Graphics -------------------------------------------------------------
  # The desktop session renders on the emulated display (QXL/virtio) either way,
  # so it starts reliably headless and is VNC/Remote-Play visible. The nvidia
  # driver is only pulled in when gpu=true (a card is present) — loading it
  # with no card just makes services fail.
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;       # Proton needs 32-bit GL
  services.xserver.enable = true;
  services.xserver.videoDrivers = if gpu then [ "modesetting" "nvidia" ] else [ "modesetting" ];
  # PINNED to legacy_580 since 2026-09-17, and this is NOT a preference. The
  # card this guest now holds is a GTX 960 (GM206) — Maxwell, which NVIDIA
  # moved to legacy support at the 580 LTSB (supported to Aug 2028). On
  # `stable`/`production` (595.84) a GM206 gets NO driver at all and the
  # failure is silent: no error, just Proton falling back to llvmpipe, which
  # reads as "Steam is broken" rather than as a driver mismatch. arcade1 ran
  # into exactly this in September and is the reason the rule is written down.
  #
  # `open = false` is forced the same way: the open kernel modules need Turing
  # or newer, so a Maxwell card cannot use them.
  #
  # COST TO KNOW ABOUT: legacy_580 is NOT in the binary cache, so any rebuild
  # that changes the kernel compiles the module inside this guest — roughly
  # ten minutes. If that build fails, comin leaves the guest on its previous
  # generation. arcade1 pays no such cost; its card is Ampere and stays on
  # `stable`. The branch follows the CARD, never the guest.
  hardware.nvidia = lib.mkIf gpu {
    modesetting.enable = true;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
  };

  # --- Desktop (Plasma 6 Wayland), auto-login ludorl82 ----------------------
  # Desktop stack (Plasma 6 + Steam + Remote Play + portal pre-auth + never
  # lock/sleep) lives in modules/arcade-desktop.nix — shared with the other
  # arcade VM. Only the auto-login user is per-host. Plasma, not GNOME: its
  # kde-authorized portal table lets us pre-authorize Steam Remote Play
  # capture; GNOME re-prompts every boot with no persist.
  services.displayManager.autoLogin.user = "ludorl82";

  # --- The player -----------------------------------------------------------
  # The player. Renamed ludo -> ludorl82 2026-08-18 (fleet-consistent admin
  # name; also lets the jumphost reach this VM as ludorl82 like every other
  # host). UID pinned to 1000 — the value ludo already had — so the migrated
  # /home/ludorl82 (moved from /home/ludo, Steam login and all) keeps its
  # ownership. Password unchanged (sha-512 hash of the original "1234").
  users.users.ludorl82 = {
    isNormalUser = true;
    uid = 1000;
    description = "ludorl82";
    extraGroups = [ "wheel" "video" "audio" "input" "networkmanager" ];
    hashedPassword = "$6$ZKBh2bnk1xddK0Dr$q35PMGrUrwnRrr.8KGsKWc1tqdce9pqoRej6BK1TYtuSLZF.RyYAfCMSbHX4xlUIFtsjDHpEYg6CwiiKgG1X21";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # Serial console on ttyS0, so `virsh console arcade2` on gaming-01 gives a login.
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  # Dedicated games disk: gaming-01's SATA SSD sdb
  # (ata-EXAMPLE_SSD_0000000000000001) passed straight through as
  # vdb (see libvirt-domain.xml), wiped + formatted ext4 with label
  # "arcade2-games" on the host. Mounted by LABEL, `nofail` so it never blocks
  # boot. Keeps the Steam library off the shared host NVMe.
  fileSystems."/games" = {
    device = "/dev/disk/by-label/arcade2-games";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10s" ];
  };
  # Steam library folder on the games disk, owned by the player. In Steam:
  # Settings -> Storage -> add /games/SteamLibrary.
  systemd.tmpfiles.rules = [ "d /games/SteamLibrary 0755 ludorl82 users - -" ];

  # VNC at arcade2.lab.example:5900 — forward to gaming-01's arcade2 VNC proxy
  # (gaming-01.lab.example:5902). LAN (VLAN10/50) + WireGuard sources only, IPv4.
  systemd.services.vnc-forward = {
    description = "Expose this VM's VNC on :5900 via gaming-01's proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat TCP4-LISTEN:5900,fork,reuseaddr TCP4:192.0.2.140:5902";
      Restart = "always";
      RestartSec = 5;
      DynamicUser = true;
    };
  };
  networking.firewall.extraCommands = ''
    # LAN + VPN (WireGuard 198.18.0.0/24 + IPsec mobile 198.18.1.0/24), IPv4.
    for net in 192.0.2.0/23 203.0.113.0/23 198.18.0.0/24 198.18.1.0/24; do
      iptables -A nixos-fw -p tcp -s "$net" --dport 5900 -j nixos-fw-accept
    done
  '';

  system.stateVersion = "26.05";
}
