# labo.vmHost — a libvirt host whose VMs can be moved, by hand, to another
# vmHost while they run. First slice of "Migrer les VM entre les X11SRA"
# (net-cfgs/backlog.md), asked for on 2026-10-08 so that bob or stella can be
# powered off without taking the console (coquille) or win11 down with it.
#
#   ssh bob sudo vm-move coquille stella
#
# No shared storage: `virsh migrate --live --copy-storage-all` streams the
# disk over NBD while the guest runs (the QNAP was ruled out as shared
# storage — it reboots on its own after a firmware update, and a wedged NFS
# mount freezes a host). Both hosts are X11SRA + W-2135, so `host-model`
# guests migrate either way.
#
# DEFINED IN ONE PLACE = THE LOCK. `--persistent --undefinesource` moves the
# definition with the guest; nothing is ever defined on two hosts, so the
# per-host autostart below can never start a second copy.
#
# Trust: each host has its own key in /var/lib/vm-move (generated on the host
# by vm-move-keygen, never in git) and accepts its peers' public keys for the
# `vmmove` user, from their VLAN10 address only. vmmove is in libvirtd (the
# qemu+ssh control connection) and may sudo exactly one thing:
# vm-move-receive, which writes a UEFI vars file for a domain this host does
# NOT define. The migration data itself goes over plain TCP between the two
# VLAN10 addresses, on qemu's 49152-49215 range, opened to the peers only.
{ config, lib, pkgs, ... }:
let
  cfg = config.labo.vmHost;
  self = config.networking.hostName;

  # The fleet's vmHosts. `moveKey` is the host's /var/lib/vm-move/id_ed25519.pub,
  # filled in AFTER the first deploy has generated it (null = not trusted yet).
  hosts = {
    bob = {
      address = "192.0.2.129";
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
      moveKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
    };
    # stella until 2026-10-16 (same machine, same keys; the moveKey comment
    # still says vm-move@stella, it is only a label).
    luna = {
      address = "192.0.2.140";
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
      moveKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
    };
  };
  peers = lib.filterAttrs (n: _: n != self) hosts;

  virsh = "${pkgs.libvirt}/bin/virsh -c qemu:///system";

  # Peer table for the script: "name address" lines.
  peerTable = pkgs.writeText "vm-move-peers"
    (lib.concatStrings (lib.mapAttrsToList (n: h: "${n} ${h.address}\n") peers));

  vmMove = pkgs.writeShellApplication {
    name = "vm-move";
    runtimeInputs = with pkgs; [ libvirt openssh coreutils gnugrep gnused gawk systemd util-linux ];
    text = builtins.readFile ../scripts/vm-move.sh;
    # The script reads its fixed paths from the environment so the test can
    # point them at fakes.
    runtimeEnv = {
      VM_MOVE_PEERS = "${peerTable}";
      VM_MOVE_KEY = "/var/lib/vm-move/id_ed25519";
      VM_MOVE_HEADROOM_KIB = toString (4 * 1024 * 1024);
    };
  };

  # Receiving end of the NVRAM pre-copy, called by the SOURCE host's vm-move
  # through its stable /run/current-system path (store paths differ between
  # hosts on different revisions). Run by vmmove through sudo with
  # exactly two arguments; refuses anything that is not a plain domain name or
  # a domain this host already defines (that file is live, not a copy).
  vmMoveReceive = pkgs.writeShellScriptBin "vm-move-receive" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.libvirt pkgs.coreutils ]}
    kind="''${1:-}"; vm="''${2:-}"
    case "$vm" in ""|*[!A-Za-z0-9_-]*) echo "denied: bad vm" >&2; exit 1 ;; esac
    [ "$kind" = nvram ] || { echo "denied: bad kind" >&2; exit 1; }
    if virsh -c qemu:///system dominfo "$vm" >/dev/null 2>&1; then
      echo "denied: $vm is defined here" >&2; exit 1
    fi
    d=/var/lib/libvirt/qemu/nvram
    install -d -m 0755 "$d"
    tmp=$(mktemp "$d/.$vm.XXXXXX")
    head -c 67108864 > "$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "denied: empty" >&2; exit 1; }
    chmod 0600 "$tmp"
    mv -f "$tmp" "$d/''${vm}_VARS.fd"
  '';
in
{
  options.labo.vmHost = {
    enable = lib.mkEnableOption "moving VMs to and from the other vmHosts";
    alwaysOn = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        VMs that must run somewhere at all times. Whichever host defines one
        saves it to disk on shutdown and resumes it on boot (cold-starts it if
        there is no save — an unclean power loss). A host that does not
        define it does nothing.
      '';
    };
    vncProxies = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      default = { };
      example = { win11 = 5903; };
      description = ''
        VM name -> fixed port on this host's VLAN10 address, proxied to the
        VM's QEMU VNC console (dynamic display, localhost only). Resolved per
        connection, so it answers on whichever host currently runs the VM.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [ {
    assertions = [{
      assertion = hosts ? ${self};
      message = "labo.vmHost: ${self} is not in modules/vm-host.nix's host table";
    }];

    # SAME MICROCODE on every vmHost. A guest started on a host whose microcode
    # reports a fix (stella: 0x2007006, GDS mitigated) inherits the matching
    # CPUID bit (`gds-no`), and libvirt then refuses to move it to a host that
    # lacks it (bob: 0x2006d05, "Vulnerable: No microcode") — seen on
    # 2026-10-08 with worker5 and win11. bob had never enabled this. Early
    # microcode loads at boot only: a host picks it up at its next reboot.
    hardware.cpu.intel.updateMicrocode = true;

    virtualisation.libvirtd.enable = true;
    # win11 has a vTPM; it must be able to land on any vmHost.
    virtualisation.libvirtd.qemu.swtpm.enable = true;

    environment.systemPackages = [ vmMove vmMoveReceive ];

    users.groups.vmmove = { };
    users.users.vmmove = {
      isSystemUser = true;
      group = "vmmove";
      extraGroups = [ "libvirtd" ];
      # libvirt's qemu+ssh runs virt-ssh-helper (or nc) through a shell.
      useDefaultShell = true;
      home = "/var/empty";
      openssh.authorizedKeys.keys = lib.mapAttrsToList
        (_: h: ''from="${h.address}",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${h.moveKey}'')
        (lib.filterAttrs (_: h: h.moveKey != null) peers);
    };
    security.sudo.extraRules = [{
      users = [ "vmmove" ];
      commands = [{ command = "/run/current-system/sw/bin/vm-move-receive"; options = [ "NOPASSWD" ]; }];
    }];
    # Peers' host keys, so the root-run migration never meets a TOFU prompt.
    programs.ssh.knownHosts = lib.mapAttrs' (n: h: lib.nameValuePair "vm-move-${n}" {
      hostNames = [ n "${n}.lab.example" h.address ];
      publicKey = h.hostKey;
    }) peers;

    systemd.services.vm-move-keygen = {
      description = "Generate this host's vm-move SSH key";
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        install -d -m 0700 /var/lib/vm-move
        [ -f /var/lib/vm-move/id_ed25519 ] || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
          -C "vm-move@${self}" -f /var/lib/vm-move/id_ed25519
      '';
    };

    # The images pool exists on every vmHost (bob had one by hand; stella had
    # none), so a moved disk has a volume to land in.
    systemd.services.vm-move-pool = {
      description = "Ensure the libvirt 'images' pool exists";
      wantedBy = [ "multi-user.target" ];
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${virsh} pool-info images >/dev/null 2>&1 || {
          ${virsh} pool-define-as images dir --target /var/lib/libvirt/images
          ${virsh} pool-autostart images
        }
        ${virsh} pool-info images | grep -q 'State:.*running' || ${virsh} pool-start images
      '';
      path = [ pkgs.gnugrep ];
    };

    # Migration + NBD ports, from the peers' VLAN10 addresses only.
    networking.firewall.extraCommands = lib.concatStrings (lib.mapAttrsToList (_: h: ''
      iptables -A nixos-fw -p tcp -s ${h.address} --dport 49152:49215 -j nixos-fw-accept
    '') peers) + lib.concatStrings (lib.mapAttrsToList (_: port: ''
      for net in 192.0.2.0/23 203.0.113.0/23 198.18.0.0/24 198.18.1.0/24; do
        iptables -A nixos-fw -p tcp -s "$net" --dport ${toString port} -j nixos-fw-accept
      done
    '') cfg.vncProxies);

    # Always-on VMs: save on host shutdown, resume (or cold start) on boot —
    # but only the ones THIS host defines. Generalises bob's former
    # vm-suspend-coquille, and keeps its two hard-won properties:
    #  - restartIfChanged = false: a deploy that changes this unit must not
    #    run its STOP (a managedsave) mid-switch — that cut the console from
    #    20:51 to 21:28 on 2026-09-30.
    #  - after libvirt-guests: its stop runs first, so guests are saved before
    #    libvirt-guests' own onShutdown policy reaches them.
    systemd.services.vm-always-on = lib.mkIf (cfg.alwaysOn != [ ]) {
      description = "Keep ${lib.concatStringsSep ", " cfg.alwaysOn} running across host power-cycles";
      wantedBy = [ "multi-user.target" ];
      restartIfChanged = false;
      after = [ "libvirtd.service" "libvirt-guests.service" "vm-move-pool.service" ];
      # wants, NOT requires: systemd propagates a stop or restart of a
      # required unit to this one, and this one's stop is a managedsave. With
      # requires, `systemctl restart libvirtd` (needed once on bob so the
      # daemon finds swtpm) would have saved coquille. Ordering stays `after`.
      wants = [ "libvirtd.service" ];
      path = [ pkgs.libvirt pkgs.gnugrep ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Two 16 GiB RAM images, written in turn.
        TimeoutStopSec = "600s";
        # `virsh start` on a domain with a managed save resumes it; without
        # one it boots cold. Domains not defined here are skipped.
        ExecStart = pkgs.writeShellScript "vm-always-on-start" ''
          for vm in ${lib.escapeShellArgs cfg.alwaysOn}; do
            ${virsh} dominfo "$vm" >/dev/null 2>&1 || continue
            [ "$(${virsh} domstate "$vm" 2>/dev/null)" = running ] && continue
            ${virsh} start "$vm" || true
          done
        '';
        ExecStop = pkgs.writeShellScript "vm-always-on-save" ''
          for vm in ${lib.escapeShellArgs cfg.alwaysOn}; do
            [ "$(${virsh} domstate "$vm" 2>/dev/null)" = running ] || continue
            ${virsh} managedsave "$vm" || true
          done
        '';
      };
    };
  }
  {
    # Fixed-port VNC consoles, LAN (VLAN10/50) + VPN sources only, IPv4 — the
    # pattern stella's arcade proxies use, moved here so it follows the VM.
    systemd.sockets = lib.mapAttrs' (vm: port: lib.nameValuePair "${vm}-vncproxy" {
      wantedBy = [ "sockets.target" ];
      socketConfig = { ListenStream = "${hosts.${self}.address}:${toString port}"; Accept = true; FreeBind = true; };
    }) cfg.vncProxies;
    systemd.services = lib.mapAttrs' (vm: _: lib.nameValuePair "${vm}-vncproxy@" {
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "${vm}-vncproxy" ''
          d=$(${virsh} vncdisplay ${vm} 2>/dev/null | ${pkgs.gnused}/bin/sed 's/.*://')
          [ -n "$d" ] || exit 1
          exec ${pkgs.socat}/bin/socat - TCP4:127.0.0.1:$((5900 + d))
        '';
        StandardInput = "socket";
        StandardOutput = "socket";
      };
    }) cfg.vncProxies;
  } ]);
}
