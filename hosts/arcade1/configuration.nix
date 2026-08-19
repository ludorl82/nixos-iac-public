## arcade1: the first gaming VM — a NixOS libvirt guest on `gaming-01` with the
## RTX 3060 passed through (gaming-01 binds it to vfio-pci; see
## hosts/gaming-01/configuration.nix). NixOS, not Windows, by request: Civ 7 runs
## under Steam Play/Proton, and the VM is a full fleet member (comin, disko,
## private-ca) instead of a hand-managed Windows box.
##
## ROLE: headless gaming host, streamed with Steam Remote Play. There is no
## physical monitor, so the nvidia X server is told to start on a virtual
## display (AllowEmptyInitialConfiguration + a Virtual modeline) and prlea56
## is auto-logged into a GNOME/Xorg session at boot, which is what Steam
## Remote Play needs running to have something to stream. Xorg (not Wayland)
## deliberately: nvidia + headless + Remote Play is far better trodden on X11.
##
## NETWORKING mirrors vm-02 (the other libvirt guest): a macvtap guest sees
## UNTAGGED traffic, so each NIC just carries a static address, matched by the
## fixed MAC set in libvirt-domain.xml. net0 = VLAN10 (.141, fleet mgmt, the
## ONLY default route); net1 = VLAN50 (.141, the home LAN where the Steam
## clients live) — address only, no gateway, per the one-default-route rule.
##
## hardware-configuration.nix (virtio initrd modules) is generated on the
## booted installer during nixos-anywhere, same as every other host.
{ config, lib, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/private-ca.nix
  ];

  # UEFI guest (OVMF in libvirt-domain.xml). systemd-boot is fine here — a VM's
  # firmware is not the broken-BIOS mess gaming-01's bare metal is.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # nvidia + Steam are unfree, allowed the same per-host way gpu-01/gpu-02 do.
  nixpkgs.config.allowUnfree = true;

  networking.hostName = "arcade1";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # net0 — VLAN10, primary, carries the default route. Matched by the MAC the
  # domain pins so it is independent of the guest's NIC name.
  systemd.network.networks."10-vlan10" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      Address = [ "192.0.2.141/23" ];   # IPv4 ONLY — see the IPv6 note below
      Gateway = "192.0.2.254";
      DNS = [ "192.0.2.254" ];
      DHCP = "no";
      # IPv4-ONLY on this macvtap. On gaming-01's VLAN10 the guest's own IPv6
      # NDP/DAD multicast gets reflected back to it, so the IPv6 link-local
      # address fails DAD in an endless "switching to alternate IPv6LL source"
      # loop — which pins the link in "configuring" and blocks the static IPv4
      # from ever committing (observed 2026-08-17: arcade1 booted with NO
      # VLAN10 address). vm-02's trustGuestRxFilters trick did NOT cure it
      # here. IPv4 is all these gaming VMs need, so disable IPv6 on this link
      # entirely: no link-local, no RA. (The arcade AAAA DNS records were
      # dropped to match.)
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
    # "~." forces every lookup at pfSense Unbound so the internal zone
    # resolves — the same line the workers carry.
    domains = [ "lab.example" "example.com" "~." ];
    linkConfig.RequiredForOnline = "routable";
  };

  # net1 — VLAN50, the home LAN where the Steam Remote Play clients are.
  # Static address only, DHCP explicitly off (it was picking up a stray Kea
  # lease + a second default route otherwise) and no gateway, so the sole
  # default route stays on VLAN10.
  systemd.network.networks."20-vlan50" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      Address = [ "203.0.113.141/23" ];
      DHCP = "no";
      LinkLocalAddressing = "ipv4";
    };
    linkConfig.RequiredForOnline = "no";
  };
  networking.search = [ "lab.example" "example.com" ];

  # qemu-guest-agent: lets gaming-01 see the VM's IPs (virsh domifaddr) and do a
  # clean guest shutdown. The channel is already in libvirt-domain.xml.
  services.qemuGuest.enable = true;

  # --- The GPU (passed-through 3060) + nvidia proprietary driver ------------
  # Inside the guest the 3060 is an ordinary PCI GPU. The desktop itself does
  # NOT run on it: modern GNOME is Wayland-only (the Xorg session was removed),
  # and a headless Wayland session on nvidia with no connected monitor is
  # fragile. So the GNOME session renders on the emulated display (QXL/virtio,
  # in libvirt-domain.xml) — which always has a virtual output, so the session
  # starts reliably headless and is visible over VNC AND capturable by Steam
  # Remote Play — while the nvidia 3060 stays loaded for the games to use.
  # `modesetting` is listed first so the emulated GPU is the primary display
  # and nvidia is the secondary/offload device.
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;   # Proton needs 32-bit GL
  services.xserver.enable = true;
  services.xserver.videoDrivers = [ "modesetting" "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open = false;                       # GA106: proprietary is the safe pick
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # --- GNOME desktop (Wayland), auto-login prlea56 --------------------------
  # Autologin gives Steam Remote Play a live session to stream on a headless
  # box. The password (hashed below) still applies to the lock screen + sudo.
  services.xserver.displayManager.gdm = {
    enable = true;
    autoSuspend = false;                # never suspend a headless streamer
  };
  services.desktopManager.gnome.enable = true;
  services.displayManager.autoLogin = { enable = true; user = "prlea56"; };

  # --- Steam + Remote Play --------------------------------------------------
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;     # opens the Remote Play/streaming ports
  };

  # This is a HEADLESS streaming host with nobody at a keyboard: prlea56 is
  # auto-logged-in, and Steam Remote Play can only stream a session that is
  # live and UNLOCKED. So GNOME must never lock, blank, idle, or sleep — set
  # those as the session defaults for every user.
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

  # Belt-and-braces at the systemd layer: never suspend/hibernate the VM, so an
  # idle streaming host can't drop offline underneath Lea.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Auto-start Steam in prlea56's session so the Remote Play host is always up
  # the moment the VM boots — no interactive launch needed. `-silent` starts it
  # minimised to the tray. (The one-time Steam *account* login is still manual,
  # done once over VNC; after that the credentials persist.)
  environment.etc."xdg/autostart/steam.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Steam
    Exec=steam -silent
    X-GNOME-Autostart-enabled=true
    NoDisplay=true
  '';

  # --- The player -----------------------------------------------------------
  # Password provided by the user (GNOME login "1234"); stored ONLY as a
  # sha-512 hash, never in plaintext. Change it later with `passwd` in the
  # guest — hashedPassword just seeds the initial value.
  users.users.prlea56 = {
    isNormalUser = true;
    description = "prlea56";
    extraGroups = [ "wheel" "video" "audio" "input" "networkmanager" ];
    hashedPassword = "$6$ZKBh2bnk1xddK0Dr$q35PMGrUrwnRrr.8KGsKWc1tqdce9pqoRej6BK1TYtuSLZF.RyYAfCMSbHX4xlUIFtsjDHpEYg6CwiiKgG1X21";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  # Passwordless sudo for wheel, fleet-consistent.
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # A serial console on the guest's virtio/isa serial, so `virsh console
  # arcade1` from gaming-01 gives a real login without needing the GPU/display.
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  # Dedicated games disk: gaming-01's SATA SSD sda
  # (ata-Example_SA400S37240G_50026B7282EA4F50) passed straight through as
  # vdb (see libvirt-domain.xml), wiped + formatted ext4 with label
  # "arcade1-games" on the host. Mounted by LABEL so it is independent of
  # device order, and `nofail` so a missing/detached disk never blocks boot —
  # the OS lives on the NVMe qcow2 regardless. Keeps the ~40 GB Civ 7 + the
  # rest of the Steam library off the shared host NVMe.
  fileSystems."/games" = {
    device = "/dev/disk/by-label/arcade1-games";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10s" ];
  };
  # A Steam library folder on the games disk, owned by the player. In Steam:
  # Settings -> Storage -> add /games/SteamLibrary.
  systemd.tmpfiles.rules = [ "d /games/SteamLibrary 0755 prlea56 users - -" ];

  # VNC at arcade1.lab.example:5900 — forward to gaming-01's arcade1 VNC proxy
  # (gaming-01.lab.example:5901), which reaches this VM's own QEMU VNC. Restricted
  # below to LAN (VLAN10/50) + WireGuard sources, IPv4 only.
  systemd.services.vnc-forward = {
    description = "Expose this VM's VNC on :5900 via gaming-01's proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat TCP4-LISTEN:5900,fork,reuseaddr TCP4:192.0.2.140:5901";
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
