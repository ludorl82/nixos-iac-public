## arcade2: the second gaming VM — a NixOS libvirt guest on `gaming-01`, twin of
## arcade1. Created 2026-08-17 BEFORE its GPU exists: a spare RTX 3050 will be
## added to gaming-01 when the user is back from vacation, then passed through
## here. Until then arcade2 runs on the emulated display only (no nvidia).
##
## TO ENABLE THE GPU once the RTX 3050 is physically in gaming-01:
##   1. gaming-01: add the 3050's PCI id to `vfio-pci.ids` in
##      hosts/gaming-01/configuration.nix (find it with `lspci -nn` / sysfs — it
##      is NOT 10de:2503; a 3050 is a different GA107/GA106 id) + its audio fn,
##      and reboot gaming-01 so vfio claims it.
##   2. arcade2: flip `gpu` below to true.
##   3. add the <hostdev> for the 3050 (+ audio) to hosts/arcade2/libvirt-
##      domain.xml, then `virsh define` it and fully stop/start arcade2.
## The nvidia driver + 32-bit GL + videoDrivers only turn on when gpu=true, so
## arcade2 stays clean (no nvidia-without-a-card failures) until then.
##
## Everything else mirrors arcade1: GNOME auto-login (ludorl82), Steam + Remote
## Play, never lock/sleep, dual-homed VLAN10 .142 / VLAN50 .142, MAC-matched.
{ config, lib, pkgs, ... }:
let
  # Flip to true (and do the domain/vfio steps above) once the RTX 3050 is
  # installed and passed through. false = emulated display only, no nvidia.
  gpu = false;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/private-ca.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nixpkgs.config.allowUnfree = true;

  networking.hostName = "arcade2";
  networking.useNetworkd = true;
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
  };

  # net1 — VLAN50, home LAN (Steam clients). Static only, DHCP off, no gateway.
  systemd.network.networks."20-vlan50" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      Address = [ "203.0.113.142/23" ];
      DHCP = "no";
      LinkLocalAddressing = "ipv4";
    };
    linkConfig.RequiredForOnline = "no";
  };
  networking.search = [ "lab.example" "example.com" ];

  services.qemuGuest.enable = true;

  # --- Graphics -------------------------------------------------------------
  # The GNOME session renders on the emulated display (QXL/virtio) either way,
  # so it starts reliably headless and is VNC/Remote-Play visible. The nvidia
  # driver is only pulled in when the 3050 is present (gpu=true) — loading it
  # with no card just makes services fail.
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;       # Proton needs 32-bit GL
  services.xserver.enable = true;
  services.xserver.videoDrivers = if gpu then [ "modesetting" "nvidia" ] else [ "modesetting" ];
  hardware.nvidia = lib.mkIf gpu {
    modesetting.enable = true;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # --- GNOME desktop (Wayland), auto-login ludorl82 ---------------------------
  services.xserver.displayManager.gdm = {
    enable = true;
    autoSuspend = false;
  };
  services.desktopManager.gnome.enable = true;
  services.displayManager.autoLogin = { enable = true; user = "ludorl82"; };

  # --- Steam + Remote Play --------------------------------------------------
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
  };

  # Never lock/blank/idle/sleep — a headless streaming session must stay live.
  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.desktop.screensaver]
    lock-enabled=false
    idle-activation-enabled=false

    [org.gnome.desktop.session]
    idle-delay=uint32 0

    [org.gnome.settings-daemon.plugins.power]
    sleep-inactive-ac-type='nothing'
    sleep-inactive-battery-type='nothing'
    idle-dim=false
    power-button-action='nothing'
  '';
  services.desktopManager.gnome.extraGSettingsOverridePackages = [
    pkgs.gnome-settings-daemon
    pkgs.gsettings-desktop-schemas
  ];

  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Auto-start Steam so the Remote Play host is up as soon as the VM boots.
  environment.etc."xdg/autostart/steam.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Steam
    Exec=steam -silent
    X-GNOME-Autostart-enabled=true
    NoDisplay=true
  '';

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
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # Serial console on ttyS0, so `virsh console arcade2` on gaming-01 gives a login.
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  # Dedicated games disk: gaming-01's SATA SSD sdb
  # (ata-Example_SA400S37240G_50026B7282EA3CF3) passed straight through as
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
