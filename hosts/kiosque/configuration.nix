## kiosque: the rack's screen, on its own machine. An X9SCM-F (Xeon E3-1230 V2,
## 32 GB) — the board vega ran on until it moved to an X11SRA — in a
## Q300L on a rack shelf. Ludo's decision of 2026-10-13/14: the kiosk leaves
## stella so that stella's reboots and game mode no longer take the rack's
## screen with them, and the RTX 3050 goes back to k3s alone.
##
## The kiosk (modules/kiosk.nix, `driver = "radeon"`) moved here from stella
## on 2026-10-14, with the numpad and the rack keyboard; the two UGREEN
## capture cards stay on stella and come through an SSH tunnel. The host
## itself was installed the same day (#180).
##
## Hardware, read from the installer on 2026-10-14 (not from memory):
##   - Matrox G200eW (06:03.0, mgag200): the onboard VGA, the BMC's iKVM, the
##     console — the role the ASPEED plays on stella.
##   - Radeon "Cedar" (02:00.0, 1002:68f9, 1 GB, `radeon` driver — TeraScale 2,
##     too old for amdgpu): DVI, HDMI, VGA; its HDMI is in the BenQ. The
##     future kiosk seat.
##   - Renesas uPD720201 USB 3 card (03:00.0): for the capture cards.
##   - enp0s25 (82579LM, 02:00:00:00:00:01) is the cabled port; eno1
##     (82574L) and a USB Ethernet adapter are unused.
{ lib, ... }:
{
  imports = [ ./hardware-configuration.nix ../../modules/private-ca.nix ../../modules/caps-ctrl.nix ../../modules/kiosk.nix ];

  networking.hostName = "kiosque";

  labo.gpus = [
    { slot = "02:00.0"; id = "1002:68f9"; audioId = "1002:aa68"; model = "Radeon HD 5000/6000/7350"; die = "Cedar"; vram = "1 Go"; }
  ];

  # The rack kiosk, on the Radeon's HDMI into the BenQ, as logind seat1; the
  # Matrox (VGA, the BMC's iKVM) keeps the console. Keys (Ludo): 3 = luna
  # (stella until 2026-10-16), 4 = bob (2026-10-09); 5 = this host's own
  # console, 6 and 7 = the work laptop's two screens (2026-10-14); 2 = stella,
  # the X11SRA-RF that was encodeur (2026-10-17); 1 = vega (eventreur), through
  # its HDMI output and a capture card on this box (2026-10-18). Numpad:
  # "SINO WEALTH Gaming KB" (258a:003a = 9610:58), read with evtest on stella.
  labo.kiosk = {
    enable = true;
    driver = "radeon";
    desktops = [
      # vega has no BMC: its HDMI goes into a UGREEN 15389 (MacroSilicon, USB 3,
      # MJPEG 1080p60 listed by v4l2-ctl) on this box's Renesas USB 3 card. Its
      # own serial, so by-id is safe here (unlike luna's two 25173). Served on
      # 127.0.0.1:8101 only, no tunnel.
      { kind = "capture"; name = "vega"; key = 1;
        device = "/dev/v4l/by-id/usb-MACROSILICON_UGREEN_15389_20230204-video-index0"; }
      { kind = "bmc"; name = "stella"; key = 2; }
      { kind = "bmc"; name = "luna"; key = 3; }
      { kind = "bmc"; name = "bob"; key = 4; }
      # The two UGREEN cards stay plugged into luna (their cables do not
      # reach this box): served there on 127.0.0.1, reached through the SSH
      # tunnel (modules/kiosk-capture.nix). Never in clear on the network.
      # The X9SCM's iKVM is Java only: kiosque's console is a terminal here.
      { kind = "console"; name = "kiosque"; key = 5; }
      { kind = "capture"; name = "bureau"; key = 6; host = "luna"; }
      { kind = "capture"; name = "bureau2"; key = 7; host = "luna"; }
    ];
    # luna's (stella until 2026-10-16) /etc/ssh/ssh_host_ed25519_key.pub, read on 2026-10-14.
    captureHostKeys.luna = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
    numpad = [ "9610:58:SINO_WEALTH_Gaming_KB" ];
    # The cube; sway takes over by itself if Wayfire keeps dying.
    compositor = "wayfire";
    numpadDevice = "/dev/input/by-id/usb-SINO_WEALTH_Gaming_KB-event-kbd";
  };

  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    netdevs."10-vlan10" = {
      netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
      vlanConfig.Id = 10;
    };
    # The cabled port, by MAC: a trunk with VLAN 10 tagged (checked from the
    # installer on 2026-10-14: 192.0.2.254 answered on a test vlan10) and
    # VLAN 50 native. The untagged side takes a DHCP lease but NO route and
    # NO DNS from it: it is a way back in from VLAN 50 (bob, coquille, the
    # Mac are on-link there) if VLAN 10 is ever misconfigured, never the
    # path out. The default route stays on vlan10 alone.
    #
    # Type = "ether" is LOAD-BEARING: a VLAN netdev inherits its parent's MAC,
    # so a match on the MAC alone also caught vlan10, and this file sorts
    # before 20-vlan10 — vlan10 came up in DHCP with no address and no route
    # (first boot, 2026-10-14; fixed from the VLAN 50 side).
    networks."10-uplink" = {
      matchConfig = { MACAddress = "02:00:00:00:00:01"; Type = "ether"; };
      vlan = [ "vlan10" ];
      networkConfig.DHCP = "ipv4";
      dhcpV4Config = { UseGateway = false; UseRoutes = false; UseDNS = false; UseNTP = false; };
      linkConfig.RequiredForOnline = "no";
    };
    # IPv6 follows the hex(last-octet) convention: .10 -> ::a.
    networks."20-vlan10" = {
      matchConfig.Name = "vlan10";
      address = [
        "192.0.2.10/23"
        "2001:db8:50:a::a/64"
      ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig = { DHCP = "no"; DNS = "192.0.2.254"; IPv6AcceptRA = true; };
      # "~.": pfSense's Unbound answers everything, or resolved falls back to
      # public servers that cannot see lab.example (the worker5/encodeur trap).
      domains = [ "lab.example" "example.com" "~." ];
    };
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.ludorl82 = {
    isNormalUser = true;
    # Console password = KeePass entry "Linux", as on the other hosts: only
    # its sha-512 hash, seeded by hand (root 600, never in git). Missing file
    # = the account stays locked; SSH is key-only either way.
    hashedPasswordFile = "/var/lib/secrets/ludorl82.hash";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  system.stateVersion = "26.11";
}
