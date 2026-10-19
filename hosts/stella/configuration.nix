## NixOS config for stella - a k3s GPU node (RTX 3060 Laptop) on a Supermicro
## X11SRA-RF, BMC 192.0.2.8 (iKVM HTML5, KeePass "X11SRA-RF IPMI (stella)").
##
## This host was `encodeur` (X9SCM, Frigate's dedicated NVR) until 2026-10-17:
## its disks moved onto the X11SRA-RF, Frigate moved to luna
## (modules/frigate-host.nix) and the box took the name stella, freed when the
## previous stella became luna. Its role beyond "k3s node with a GPU" is
## still open. backup-vg still holds the old frigate-lv (unmounted, kept until
## Frigate has proven itself on luna).
##
## hardware-configuration.nix carries the initrd storage modules
## (ahci/sd_mod/...) - omitting those is what made vega's first
## install unbootable, so it's imported here from the start.
##
## systemd-networkd VLAN10 config (proven pattern), static 192.0.2.98.
{ config, lib, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ../../modules/k3s-agent.nix ../../modules/private-ca.nix ../../modules/ups-client.nix ../../modules/caps-ctrl.nix ];

  ## --node-label only takes effect at first registration (the rename makes
  ## this a fresh `stella` node). No taint any more: the dedicated=frigate
  ## taint left with Frigate; svclb-traefik may land here like on any node,
  ## which is fine as long as nothing on the host binds 80/443.
  services.k3s.extraFlags = [
    "--node-ip=192.0.2.98"
    "--node-label=gpu=nvidia"
  ];

  ## RTX 3060 Laptop (GA106M, 10de:2520), driven by the host for k3s, never
  ## passed through. Slot re-read on the X11SRA-RF on 2026-10-17 (65:00.0;
  ## it was 02:00.0 on the X9SCM). It froze POST (code 94) under BIOS 2.0a;
  ## fine since BIOS 3.2 with slot OPROM disabled and Above 4G on.
  labo.gpus = [
    { slot = "65:00.0"; id = "10de:2520"; audioId = "10de:228e"; model = "RTX 3060 Laptop"; die = "GA106M"; vram = "6 Go"; }
  ];

  nixpkgs.config.allowUnfree = true;
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    package = import ../../modules/nvidia-driver.nix {
      inherit (config.boot.kernelPackages) nvidiaPackages;
    };
    open = false;
    modesetting.enable = true;
    nvidiaSettings = false;
  };
  hardware.nvidia-container-toolkit.enable = true;
  ## k3s writes its own containerd config and auto-adds an `nvidia` runtime
  ## (which is what the Frigate pod's `runtimeClassName: nvidia` selects)
  ## only if it finds `nvidia-container-runtime` while scanning $PATH at
  ## startup. On a normal distro that's /usr/bin; on NixOS it's a /nix/store
  ## path k3s would never look in, so put it on the k3s unit's PATH.
  ## Two traps here, both cost time:
  ##   - the runtime binaries are in the toolkit's `tools` OUTPUT; the
  ##     default output only ships `nvidia-ctk` and detection silently fails.
  ##     BOTH outputs are needed: the runtime bakes a createContainer hook
  ##     into the OCI spec and resolves `nvidia-ctk` off its own PATH,
  ##     falling back to a hardcoded /usr/bin/nvidia-ctk that will never
  ##     exist here ("error running createContainer hook #0: fork/exec
  ##     /usr/bin/nvidia-ctk: no such file or directory").
  ##   - nvidia-container-runtime is a shim that execs a real low-level
  ##     runtime and looks for `runc`/`crun` on ITS OWN PATH, so runc has to
  ##     be here too or every container on this node dies with
  ##     "no runtime binary found from candidate list: [runc crun]".
  systemd.services.k3s.path = [
    pkgs.nvidia-container-toolkit.tools
    pkgs.nvidia-container-toolkit
    pkgs.runc
  ];

  environment.systemPackages = [ pkgs.pciutils ];

  ## Frigate (ports, low-res feed, cron side-cars, aws pull key, data) lives
  ## on luna since 2026-10-17 (modules/frigate-host.nix). The old
  ## frigate-lv on backup-vg is left unmounted, not deleted, for now.

  ## The other LV of the same backup-vg (adopted 2026-09-16): 335 GB ext4,
  ## Blu-ray scratch (`BD3D2MK3D`), same shape as bob's and vega's.
  ## `nofail`: nothing here depends on it.
  fileSystems."/mnt/backup" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=30s" ];
  };

  ## The minimal base left this at the NixOS default of UTC, which broke two
  ## things at once: Frigate's pod bind-mounts /etc/localtime as a hostPath
  ## with `type: File`, and on a stock NixOS that path doesn't exist at all,
  ## so the pod hangs in ContainerCreating on FailedMount; and the low-res
  ## feed names its segments with a local-time strftime pattern. Matches the
  ## Ubuntu install this host replaced (and bob, where Frigate was parked).
  time.timeZone = "America/Toronto";

  networking.hostName = "stella";
  # Routage par source pour la patte VLAN50 : voir modules/dual-homed-routing.nix.
  labo.dualHomed = {
    enable = true;
    octet = 98;
    vlan10Network = "20-vlan10";
    vlan50Network = "10-eno1";
  };
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    netdevs."10-vlan10" = {
      netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
      vlanConfig.Id = 10;
    };
    # Untagged = VLAN50. Secondary: address only, deliberately NO gateway, so
    # the default route stays exclusively on VLAN10 - that's also what keeps
    # aws reachable over the WireGuard tunnel (a VLAN50 default route would
    # send tunnel replies out the wrong interface). Not required for
    # network-online so a VLAN50 hiccup can't hang boot.
    networks."10-eno1" = {
      matchConfig.Name = "eno1";
      vlan = [ "vlan10" ];
      address = [ "203.0.113.98/23" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # Tagged VLAN10 = primary, and the only interface with a gateway.
    # IPv6 follows the hex(last-octet) convention (98 -> 0x62); the v6
    # default route comes from pfSense's RA.
    networks."20-vlan10" = {
      matchConfig.Name = "vlan10";
      address = [
        "192.0.2.98/23"
        "2001:db8:50:a::62/64"
      ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig.DNS = "192.0.2.254";
      networkConfig.IPv6AcceptRA = true;
      # "~." makes pfSense's Unbound the resolver for *everything*. Without
      # it systemd-resolved falls back to its built-in public servers
      # (1.1.1.1 & co.), which cannot resolve the internal lab.example zone:
      # public names work, every homelab name is NXDOMAIN. Same trap as
      # worker5. Here it silently broke all three Frigate Kuma push
      # monitors - the watchdog scripts log a push failure and still exit 0,
      # so the only symptom would have been monitors going stale.
      domains = [ "lab.example" "example.com" "~." ];
    };
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.ludorl82 = {
    isNormalUser = true;
    # Console password (iKVM, rack screen) = KeePass entry "Linux", asked for
    # on 2026-10-09. Only its sha-512 HASH, seeded by hand on the host (root
    # 600, never in git: the repo is published sanitized and a published hash
    # can be cracked offline). sudo does not ask for it (wheelNeedsPassword =
    # false) and SSH stays key-only. Missing file = the account stays locked.
    hashedPasswordFile = "/var/lib/secrets/ludorl82.hash";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      # bob is the fleet's build/deploy host (same key worker5 carries); it
      # also had to push Frigate's data back here during the bob->encodeur
      # migration, which is what finally backfilled this.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  system.stateVersion = "26.05";
}
