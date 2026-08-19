## NixOS config for gpu-01 - the amd64 workhorse (2x RTX 3060, 109G RAM,
## 931G NVMe). Converted last in the fleet since it was the Nix build host
## + k3s workload home; its services were migrated off first (see the gpu-01
## drain). Minimal base + k3s here; the two follow-ups its old role needs:
##   - NVIDIA driver stack for the 2x RTX 3060 (general GPU capacity)
##   - libvirtd, if gpu-01 hosts VMs again (vm-01/cp-3 are retired, so
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
    ../../modules/ups-cp-1.nix
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
    # Just an admin login now — the video/render groups were only for
    # gnome-shell's GPU access, dropped with the desktop (2026-08-18).
    extraGroups = [ "wheel" ];
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
  # On host power-off, gracefully ACPI-shut-down guests and cold-start them on
  # boot. This is the correct treatment for vm-01 (a k3s node — clean shutdown
  # + cold rejoin beats suspend/resume, which strands it with a stale clock and
  # etcd-lease churn). console-vm is the EXCEPTION: the oneshot below saves/restores
  # its RAM state so the admin console survives a gpu-01 power-cycle unchanged. Its
  # ExecStop runs (ordered before libvirt-guests stops) while console-vm is still
  # up, managedsaves it, so libvirt-guests then finds it already down and skips
  # it. gpu-01's HA "off" is a graceful BMC `power soft`, so these hooks run.
  virtualisation.libvirtd.onShutdown = "shutdown";
  virtualisation.libvirtd.onBoot = "start";

  # console-vm (admin/console VM, NOT a cluster node): suspend-to-disk on host
  # shutdown, restore on boot — unlike vm-01 it holds live interactive state
  # worth preserving. managedsave writes its ~16 G of RAM to
  # /var/lib/libvirt/qemu/save (gpu-01 has hundreds of GB free).
  systemd.services.vm-suspend-console-vm = {
    description = "Suspend/restore the console-vm VM across host power-cycles";
    wantedBy = [ "multi-user.target" ];
    # Order so ExecStop fires BEFORE libvirt-guests tears guests down, and
    # ExecStart fires AFTER libvirtd is back up on boot.
    after = [ "libvirtd.service" "libvirt-guests.service" ];
    requires = [ "libvirtd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Give managedsave time to write console-vm's full RAM to disk on shutdown.
      TimeoutStopSec = "300s";
      # Restore on boot only if a saved image exists (fresh boots have none).
      ExecStart = pkgs.writeShellScript "console-vm-restore" ''
        ${pkgs.libvirt}/bin/virsh -c qemu:///system list --with-managed-save --name 2>/dev/null | ${pkgs.gnugrep}/bin/grep -qx console-vm \
          && ${pkgs.libvirt}/bin/virsh -c qemu:///system start console-vm || true
      '';
      # Save on shutdown only if console-vm is currently running.
      ExecStop = pkgs.writeShellScript "console-vm-suspend" ''
        [ "$(${pkgs.libvirt}/bin/virsh -c qemu:///system domstate console-vm 2>/dev/null)" = running ] \
          && ${pkgs.libvirt}/bin/virsh -c qemu:///system managedsave console-vm || true
      '';
    };
  };

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

  # This host runs HEADLESS. Gaming moved to the arcade VMs on gaming-01
  # (2026-08-18), so GDM, GNOME, Steam, PipeWire and the Remote Play firewall
  # ports were all removed, along with the autologin/getty workarounds and the
  # GNOME-pulls-NetworkManager mkForce. The nvidia DRIVER above stays — Ollama's
  # CUDA and k3s GPU workloads need it; a desktop does not.
  #
  # Sleep stays masked at the systemd level regardless: a server must never
  # suspend. gpu-01 suspended at 19:01 on 2026-07-25 (GNOME idle-suspend, since
  # gone), taking k3s and the vm-01 guest down with it and looking exactly
  # like a hard power-off from the network — a WoL magic packet resumed it.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Ollama, moved here from gaming-01 on 2026-08-17 ahead of gaming-01's
  # Windows→NixOS conversion. Home Assistant's voice pipeline talks to this,
  # so it has to be serving HERE before gaming-01 is wiped, not after. gpu-01
  # already carries the CUDA stack for the two 3060s, so this is a service
  # declaration rather than a driver project.
  #
  # Bound to 0.0.0.0 to match what gaming-01 exposed (the HA integration and
  # the ha-ollama watchdog both dial it over the LAN). The port is opened
  # below; note this list MERGES with the one in modules/k3s-agent.nix
  # rather than replacing it.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    host = "0.0.0.0";
    port = 11434;
    # Registry tags only. The 16k variant HA actually names is built below.
    loadModels = [ "qwen3:8b" ];
  };
  networking.firewall.allowedTCPPorts = [ 11434 ];

  # `qwen3:8b-16k` is NOT a registry tag — it is a local Modelfile variant of
  # qwen3:8b that gaming-01 carried, and HA's conversation config entry names it
  # explicitly, so the name has to exist here or the voice assistant breaks.
  # Parameters copied from gaming-01's `ollama show`: a 16k context plus Qwen's
  # recommended sampling. `ollama create` is idempotent, so this is safe to
  # re-run on every boot and every switch.
  systemd.services.ollama-qwen3-16k = {
    description = "Build the qwen3:8b-16k Modelfile variant (from gaming-01)";
    after = [ "ollama.service" "ollama-model-loader.service" ];
    requires = [ "ollama.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      OLLAMA_HOST = "127.0.0.1:11434";
      # REQUIRED, and the failure is vicious without it: the ollama CLI calls
      # envconfig.Models() at startup, which does `panic: $HOME is not
      # defined` when HOME is unset — and systemd units have no HOME by
      # default. Found 2026-08-17 after this unit sat in `activating` for
      # 20 minutes: every readiness iteration was panicking with its stderr
      # swallowed, so it looked like a slow model pull rather than a crash.
      HOME = "/var/lib/ollama";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Type=oneshot defaults TimeoutStartSec to INFINITY, so the hang above
      # was permanent and silent. Fail loudly instead.
      TimeoutStartSec = "30min";
    };
    script = ''
      set -eu
      # ollama.service being "active" does not mean the API answers yet.
      for i in $(seq 1 60); do
        if ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then break; fi
        sleep 2
      done
      # Wait for the base model too — loadModels pulls it asynchronously and
      # `create` fails if the parent is not present yet. Checked over the HTTP
      # API rather than `ollama list`: the API needs no environment at all,
      # so this stays correct even if the CLI's env expectations change again.
      for i in $(seq 1 150); do
        if ${pkgs.curl}/bin/curl -fsS --max-time 10 http://127.0.0.1:11434/api/tags 2>/dev/null \
           | ${pkgs.gnugrep}/bin/grep -q '"qwen3:8b"'; then break; fi
        sleep 4
      done
      mf=$(mktemp)
      cat > "$mf" <<'EOF'
FROM qwen3:8b
PARAMETER num_ctx 16384
PARAMETER repeat_penalty 1
PARAMETER temperature 0.6
PARAMETER top_k 20
PARAMETER top_p 0.95
EOF
      ${config.services.ollama.package}/bin/ollama create qwen3:8b-16k -f "$mf"
      rm -f "$mf"
    '';
  };

  environment.systemPackages = with pkgs; [ virt-manager pciutils ];

  system.stateVersion = "26.05";
}
