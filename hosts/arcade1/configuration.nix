## arcade1: the first gaming VM — a NixOS libvirt guest on `gaming-01` with the
## GPU at PCI b4:00.0 passed through, an RTX 3050 6GB (GA107) since 2026-09-17
## (gaming-01 binds it to vfio-pci; see hosts/gaming-01/configuration.nix). NixOS, not Windows, by request: Civ 7 runs
## under Steam Play/Proton, and the VM is a full fleet member (comin, disko,
## private-ca) instead of a hand-managed Windows box.
##
## ROLE: headless gaming host, streamed with Steam Remote Play. There is no
## physical monitor, so the nvidia X server is told to start on a virtual
## display (AllowEmptyInitialConfiguration + a Virtual modeline) and player-01
## is auto-logged into a Plasma 6 (Wayland) session at boot, which is what Steam
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
    ../../modules/arcade-desktop.nix
  ];

  # Gaming guest: on only while someone is playing.
  labo.onDemand = true;

  # UEFI guest (OVMF in libvirt-domain.xml). systemd-boot is fine here — a VM's
  # firmware is not the broken-BIOS mess gaming-01's bare metal is.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # nvidia + Steam are unfree, allowed the same per-host way gpu-01/gpu-02 do.
  nixpkgs.config.allowUnfree = true;

  networking.hostName = "arcade1";
  networking.useNetworkd = true;
  # A desktop session turns NetworkManager on by default and it then FIGHTS networkd:
  # it DHCPs enp2s0 (stray Kea lease + a second default route) and keeps
  # re-activating "Wired connection 1" on enp1s0, which wipes the static
  # VLAN10 address (arcade1 lost 192.0.2.141 on 2026-08-22 — VNC, ping and
  # Steam all unreachable on the fleet side). networkd owns the NICs; NM off.
  networking.networkmanager.enable = lib.mkForce false;
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
    # Source-based policy routing (added 2026-08-22): a reply sourced from the
    # VLAN10 address must leave via VLAN10/pfSense even when the peer sits on
    # the directly-connected VLAN50 subnet. Without this a VLAN50 Steam client
    # that resolved arcade1.lab.example to the VLAN10 address got its replies
    # straight out of enp2s0 (asymmetric: pfSense never saw the return leg and
    # dropped the state). Table 10 = the VLAN10 view of the world; the rule
    # picks it by source address. The main table keeps its single default route.
    routes = [
      { Destination = "192.0.2.0/23"; Table = 10; }
      { Gateway = "192.0.2.254"; Table = 10; }
    ];
    routingPolicyRules = [
      { From = "192.0.2.141/32"; Table = 10; Priority = 100; }
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

  # qemu-guest-agent: lets gaming-01 see the VM's IPs (virsh domifaddr) and do a
  # clean guest shutdown. The channel is already in libvirt-domain.xml.
  services.qemuGuest.enable = true;

  # --- The passed-through GPU + nvidia proprietary driver -------------------
  # Since 2026-09-17 that card is an RTX 3050 6GB (GA107) at b4:00.0 — the one
  # arcade2 used to hold. Before it: the 8GB GA106 (now gaming-01's own, for k3s),
  # a GTX 960 for three days, an RTX 3060 before that. Deliberately not named
  # in the options below: what the guest needs is true of any of them.
  # Inside the guest the card is an ordinary PCI GPU. The desktop itself does
  # NOT run on it: modern desktops are Wayland-only (GNOME/Plasma dropped Xorg),
  # and a headless Wayland session on nvidia with no connected monitor is
  # fragile. So the desktop session renders on the emulated display (QXL/virtio,
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
    # `open = false` matches the rest of the fleet. It is NOT a shared-with-
    # arcade2 choice any more — since 2026-09-17 arcade2 holds the Maxwell 960,
    # which forces both `legacy_580` and open = false on that guest, while this
    # one is free to choose. The two guests' driver options diverge on purpose.
    open = false;
    nvidiaSettings = true;
    # `stable` (595.84). It matched arcade2 until 2026-09-17; that guest is
    # now pinned to legacy_580 for its GTX 960, and this one stays on `stable`
    # because the GA107 is Ampere. Same rule, different answer per card.
    #
    # This was PINNED to legacy_580 from 2026-09-11 to 2026-09-14, for the
    # three days a GTX 960 stood in for the dead 3060. That pin was not
    # cosmetic: NVIDIA moved Maxwell, Pascal and Volta to legacy support at the
    # 580 branch, so a GM206 on 595 gets no driver at all — the games fall back
    # to llvmpipe and it reads as "Steam is broken" rather than as a driver
    # mismatch. With an Ampere 3050 in the slot since 2026-09-14 — the GA106
    # then, the GA107 6GB since 2026-09-17 — the constraint is gone, and
    # `stable` also comes from the binary cache, which
    # legacy_580 did not: that pin cost a ~10-minute kernel-module build on the
    # guest at every rebuild.
    #
    # If a pre-Turing card is ever put back in arcade1's slot, this has to go
    # back to legacy_580 (LTSB until Aug 2028) or the VM comes up with no
    # acceleration. The rule travels with the CARD, not with the slot: arcade2
    # is on that branch today because the GTX 960 is its card to drive — see
    # hosts/arcade2. (vm-03 was too, until it was retired on 2026-09-26.)
    #
    # SHARED CARD since 2026-09-26: win11 (Windows 11 Pro, guests/win11)
    # borrows this guest's RTX 3050 6GB whenever arcade1 is off. arcade1
    # wins — arcade-ctl shuts win11 down before starting this guest.
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # --- Desktop (Plasma 6 Wayland), auto-login player-01 -----------------------
  # Desktop stack (Plasma 6 + Steam + Remote Play + portal pre-auth + never
  # lock/sleep) lives in modules/arcade-desktop.nix — shared with the other
  # arcade VM. Only the auto-login user is per-host. Plasma, not GNOME: its
  # kde-authorized portal table lets us pre-authorize Steam Remote Play
  # capture; GNOME re-prompts every boot with no persist.
  services.displayManager.autoLogin.user = "player-01";

  # --- The player -----------------------------------------------------------
  # Password provided by the user (desktop login "1234"); stored ONLY as a
  # sha-512 hash, never in plaintext. Change it later with `passwd` in the
  # guest — hashedPassword just seeds the initial value.
  users.users.player-01 = {
    isNormalUser = true;
    description = "player-01";
    extraGroups = [ "wheel" "video" "audio" "input" "networkmanager" ];
    hashedPassword = "$6$ZKBh2bnk1xddK0Dr$q35PMGrUrwnRrr.8KGsKWc1tqdce9pqoRej6BK1TYtuSLZF.RyYAfCMSbHX4xlUIFtsjDHpEYg6CwiiKgG1X21";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  # Passwordless sudo for wheel, fleet-consistent.
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # A serial console on the guest's virtio/isa serial, so `virsh console
  # arcade1` from gaming-01 gives a real login without needing the GPU/display.
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  # Dedicated games disk: vdb = a 200 GiB sparse qcow2 on gaming-01's NVMe
  # (/var/lib/libvirt/images/arcade1-games.qcow2, see libvirt-domain.xml),
  # formatted ext4 with label "arcade1-games" from inside the guest. Mounted
  # by LABEL so it is independent of device order, and `nofail` so a missing
  # disk never blocks boot — the OS lives on its own qcow2 regardless.
  # HISTORY: until 2026-08-22 this was gaming-01's SATA SSD
  # ata-EXAMPLE_SSD_0000000000000001 passed through raw; it dropped
  # off the SATA bus under Steam writes (ata5 "failed to IDENTIFY", capacity
  # 0) and libvirt I/O-paused the VM. The library on it was lost; Steam
  # re-downloads. Don't put /games back on that SSD.
  fileSystems."/games" = {
    device = "/dev/disk/by-label/arcade1-games";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10s" ];
  };
  # A Steam library folder on the games disk, owned by the player. In Steam:
  # Settings -> Storage -> add /games/SteamLibrary.
  systemd.tmpfiles.rules = [ "d /games/SteamLibrary 0755 player-01 users - -" ];

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
