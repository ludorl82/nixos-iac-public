## NixOS config for gpu-01 - the amd64 workhorse (2x RTX 3060, 109G RAM,
## 931G NVMe). Converted last in the fleet since it was the Nix build host
## + k3s workload home; its services were migrated off first (see the gpu-01
## drain). Minimal base + k3s here; the two follow-ups its old role needs:
##   - NVIDIA driver stack for the 2x RTX 3060 (general GPU capacity)
##   - libvirtd, if gpu-01 hosts VMs again (vm-01/master3 are retired, so
##     omitted for now)
## Both mirror gpu-02's nvidia block / srv-01's libvirtd block when
## wanted.
##
## hardware-configuration.nix (initrd storage modules incl. nvme) is
## generated on the booted installer during nixos-anywhere and imported
## here - omitting it makes the install unbootable.
##
## Network: single-homed VLAN10 tagged on eno2 (eno1 is unused/down),
## static 192.0.2.129 + IPv6 ::81 (hex(129)=0x81). Same systemd-networkd
## shape as srv-01, parent eno2 instead of eno1.
{ config, lib, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/k3s-agent.nix
    ../../modules/private-ca.nix
    ../../modules/ups-master.nix
  ];

  # Killpower OPT-OUT for the rolling rack (drill #2 lesson, 2026-08-04):
  # the LX1500GU never restores output on its own after a full power-off —
  # front-button only, no auto-restart toggle exists on this firmware. So
  # cutting output guarantees a stranded rack. Instead: a UPS-driven
  # shutdown leaves the outlets HOT, the four BMCs stay powered (~5 W on
  # the battery's post-FSD reserve, then mains), and pi-02's rack-wake
  # latch (modules/rack-wake.nix, powered by the survivor OR700 with
  # pfSense) IPMI-powers everything back on when the mains return.
  systemd.shutdown."nut-killpower" =
    lib.mkForce (pkgs.writeShellScript "nut-killpower-disabled" "exit 0");

  # Fire the low-battery cascade at 50 % instead of the unit's 10 %: with
  # outlets staying hot (no killpower), the remaining half feeds the four
  # BMCs (~5 W) for many hours of wake-latch runway, and the earlier
  # trigger keeps well clear of the battery gauge's post-deep-cycle lies
  # (drill #2: "34 %" collapsed to LB instantly). Driver-level override —
  # NUT synthesizes LB at this threshold regardless of UPS firmware.
  # ignorelb is REQUIRED for the override to matter: without it usbhid-ups
  # only raises LB when the UPS firmware says so (found live 2026-08-04 —
  # the cascade sat idle at 49% until the unit's own 10%-ish signal fired).
  # With ignorelb the driver evaluates charge/runtime against the .low
  # values itself.
  power.ups.ups.qnapups.directives = [
    "override.battery.charge.low = 50"
    "ignorelb"
  ];
  services.k3s.extraFlags = [ "--node-ip=192.0.2.129" ];

  # gpu-01 is the fleet's builder ("no heavy lifting on cloud-01"): emulated
  # aarch64 lets it build the Pi images (docker-rpi4, worker sticks)
  # without needing a Pi with spare RAM.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # gpu-01 builds images and pushes them to the fleet registry on the docker
  # host — https://docker.lab.example:5000, private-CA TLS trusted via
  # private-ca.nix, so no insecure-registries needed. The leaf carries the
  # DNS name plus both IP SANs, so IP-addressed pushes verify as well.
  virtualisation.docker.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "gpu-01";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    netdevs."10-vlan10" = {
      netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
      vlanConfig.Id = 10;
    };
    # macvtap host<->guest fix: a macvtap guest (vm-01) can't reach the host
    # stack on its own parent (vlan10), so gpu-01's VLAN10 IP lives on a MACVLAN
    # over vlan10 to join that L2 domain - without it flannel gpu-01<->vm-01 is
    # dropped. Mirrors the old Ubuntu gpu-01's macvlan-host@vlan.10.
    netdevs."15-mvhost" = {
      netdevConfig = { Name = "mvhost"; Kind = "macvlan"; };
      macvlanConfig.Mode = "bridge";
    };
    # The same fix is needed on the VLAN50 side: vm-01 has a macvtap on
    # the untagged eno2 too, so gpu-01's own VLAN50 address has to move off
    # eno2 onto a macvlan or vm-01 can't reach it either. (The vlan10 half
    # above was done first and left this half broken - vm-01 could reach
    # gpu-01 on VLAN10 but not on VLAN50.) Mirrors srv-01/vm-02.
    netdevs."16-mvhost50" = {
      netdevConfig = { Name = "mvhost50"; Kind = "macvlan"; };
      macvlanConfig.Mode = "bridge";
    };
    # Untagged = VLAN50. Secondary: address only, deliberately NO gateway, so
    # the default route stays exclusively on VLAN10 - that's also what keeps
    # cloud-01 reachable over the WireGuard tunnel. Not required for
    # network-online so a VLAN50 hiccup can't hang boot. This is also the
    # parent that vm-01's second (VLAN50) macvtap NIC hangs off.
    networks."10-eno2" = {
      matchConfig.Name = "eno2";
      vlan = [ "vlan10" ];
      macvlan = [ "mvhost50" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # gpu-01's VLAN50 address, on the macvlan (moved off eno2 so the macvtap
    # guest can reach it). Secondary: address only, no gateway.
    networks."25-mvhost50" = {
      matchConfig.Name = "mvhost50";
      address = [ "203.0.113.129/23" ];
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
    # gpu-01's actual VLAN10 host address, on the macvlan.
    networks."30-mvhost" = {
      matchConfig.Name = "mvhost";
      address = [
        "192.0.2.129/23"
        "2001:db8:50:a::81/64"
      ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig = { DHCP = "no"; DNS = "192.0.2.254"; IPv6AcceptRA = true; };
      domains = [ "lab.example" "example.com" "~." ];
    };
  };
  networking.search = [ "lab.example" "example.com" ];

  users.users.ludorl82 = {
    isNormalUser = true;
    # video+render: gnome-shell must open /dev/dri/card2 + renderD* itself
    # (autologin races logind's seat ACLs); without them the Wayland session
    # dies with "GPU /dev/dri/card2 ... not supported by EGL" and GDM falls
    # back to the greeter.
    extraGroups = [ "wheel" "video" "render" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # libvirt/qemu-kvm host - gpu-01 hosts the vm-01 NixOS VM (macvtap on
  # vlan10), same as srv-01 hosts vm-02. virt-manager provides
  # virt-install; OVMF/UEFI firmware ships by default.
  virtualisation.libvirtd.enable = true;

  # 2x RTX 3060 (GA106) as general GPU capacity for k3s workloads. Same
  # stack as gpu-02 - see that host's config for the full rationale on
  # the k3s PATH traps below (they cost real time there).
  nixpkgs.config.allowUnfree = true;
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.production;
    open = false;
    modesetting.enable = true;
    nvidiaSettings = false;
  };
  hardware.nvidia-container-toolkit.enable = true;
  # k3s only auto-registers the `nvidia` containerd runtime if it finds
  # nvidia-container-runtime on its PATH at startup; the runtime binaries
  # live in the toolkit's `tools` output (BOTH outputs needed), and the
  # runtime shim needs runc on its PATH too. This list MERGES with the
  # k3s-agent module's nfs-utils entry.
  systemd.services.k3s.path = [
    pkgs.nvidia-container-toolkit.tools
    pkgs.nvidia-container-toolkit
    pkgs.runc
  ];

  # GNOME desktop + Steam so gpu-01 doubles as a Steam Remote Play host
  # (stream from gpu-01 to other devices via Steam Link / "connect to").
  # GDM runs Wayland fine here since nvidia modesetting is already on.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
  # GNOME pulls in NetworkManager by default, which would fight networkd
  # for eno2/vlan10/mvhost - same trap as the Pi5 nvmd image.
  networking.networkmanager.enable = lib.mkForce false;
  # Remote Play needs a live desktop session with Steam running; auto-login
  # keeps that true across reboots without a keyboard plugged in.
  services.displayManager.autoLogin = {
    enable = true;
    user = "ludorl82";
  };
  # GDM autologin races the getty units at boot without these (NixOS wiki
  # standard workaround).
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # GNOME idle-suspends on AC after ~20min by default. On a server that is
  # catastrophic and non-obvious: gpu-01 suspended at 19:01 on 2026-07-25,
  # taking k3s and the vm-01 guest down with it, and looked exactly like a
  # hard power-off from the network (a WoL magic packet resumed it). Mask
  # sleep at the systemd level so nothing - GNOME, logind, or a stray
  # systemctl suspend - can ever put this host to sleep.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };
  # Belt-and-braces so the greeter/session never even tries (and no idle
  # countdown appears in the shell).
  services.displayManager.gdm.autoSuspend = false;
  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.settings-daemon.plugins.power]
    sleep-inactive-ac-type='nothing'
    sleep-inactive-battery-type='nothing'

    [org.gnome.desktop.screensaver]
    lock-enabled=false

    [org.gnome.desktop.lockdown]
    disable-lock-screen=true
  '';

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  programs.steam = {
    enable = true;
    # Opens 27031-27036 (Remote Play discovery/streaming) in the NixOS
    # firewall - without this Steam Link clients can't find or reach gpu-01.
    remotePlay.openFirewall = true;
  };

  environment.systemPackages = with pkgs; [ virt-manager pciutils ];

  system.stateVersion = "26.05";
}
