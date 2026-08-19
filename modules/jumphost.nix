# The jumphost role — pi-02 only, ever. Successor of console-host.nix
# after the 2026-08-07 jumphost/console split: the interactive console
# moved to the console-vm VM on gpu-01 (console-container.nix); what stays
# here is the service surface other machines depend on, deliberately
# co-located with pfSense + the WAN modem on the survivor OR700:
#   - the forced-command key surface (:22): KeePass pipeline triggers
#     from cloud-01, kp-get passphrase fetches from the whole fleet, the
#     Cronicle backup/weekly/wan-ip/ha-backup entry points
#   - the singletons: onedrive-sync ("exactly one host runs this"),
#     wan-ip-sync
# Single-host import IS the singleton guard — there is no role flag; a
# second importer would double-run OneDrive, so don't.
#
# Out-of-band seeds (beyond jumphost-tools.nix's): /opt/scripts/ and
# ~/scripts/ hold the runtime copies of scripts/jumphost/ and scripts/
# from this repo (source of truth in git since 82b9e07; the forced
# commands still point at the console-vm-era absolute paths).
{ config, pkgs, lib, ... }:
let
  kpGet = import ./kp-get.nix { inherit pkgs; };

  # The KDF speed-up helper both process_keepass*.py shell out to. It arrived
  # here as a Debian-built dynamic binary rsynced from console-vm, which NixOS
  # cannot exec at all (no /lib/ld-linux-aarch64.so.1) — so from the
  # 2026-08-05 cutover until 2026-08-07 every run silently took the
  # pure-Python fallback, ~5.5s instead of ~0.5s per KDF. Built from source
  # here so it survives the next reimage.
  aesKdfTransform = pkgs.runCommandCC "aes-kdf-transform" {
    buildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -o $out/bin/aes_kdf_transform ${./aes_kdf_transform.c} -lcrypto
  '';

  # Home Assistant fleet power control. HA's forced-command key can ONLY run
  # this — it reads `<node> <on|off|status>` from $SSH_ORIGINAL_COMMAND and does
  # nothing else (same shape as gaming-01's arcade-ctl). Supermicro x86 boards go
  # through their BMC (ipmitool, password from kp-get piped via IPMI_PASSWORD —
  # never argv); off is `power soft` (graceful ACPI) so the OS shuts down cleanly
  # and libvirt-guests can suspend console-vm. The two VM k3s workers + console-vm go
  # through virsh on their host. status is normalised to on/off/running for HA.
  powerCtl = pkgs.writeShellScript "power-ctl" ''
    export PATH=${lib.makeBinPath [ pkgs.ipmitool pkgs.openssh pkgs.wakeonlan pkgs.iputils pkgs.gnugrep pkgs.gawk pkgs.coreutils ]}:/run/current-system/sw/bin:$PATH
    set -- $SSH_ORIGINAL_COMMAND
    node="$1"; action="$2"

    bmc() {  # $1 bmc-ip  $2 kp-entry  $3 on|soft|status
      local pw; pw="$(kp-get "$2" 2>/dev/null)"
      if [ "$3" = status ]; then
        IPMI_PASSWORD="$pw" ipmitool -I lanplus -H "$1" -U ADMIN -E chassis power status 2>/dev/null | awk '{print $NF}'
      else
        IPMI_PASSWORD="$pw" ipmitool -I lanplus -H "$1" -U ADMIN -E chassis power "$3" >/dev/null 2>&1
      fi
    }
    vm() {  # $1 host  $2 vm  $3 start|shutdown|domstate
      ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" "sudo virsh -c qemu:///system $3 $2" 2>/dev/null | ${lib.getExe' pkgs.gnused "sed"} -n 1p
    }

    case "$node" in
      gpu-01)       ip=192.0.2.5; kp="X11SRA-RF IPMI (gpu-01)" ;;
      gaming-01)   ip=192.0.2.6; kp="X11SRA-RF IPMI (gaming-01)" ;;
      gpu-02)  ip=192.0.2.8; kp="X9SCM IPMI (gpu-02)" ;;
      srv-01) ip=192.0.2.7; kp="X9SCM IPMI (srv-01)" ;;
      vm-01|vm-02|console-vm) ip="" ;;
      qnap)      ip="" ;;
      *) echo "denied: bad node"; exit 1 ;;
    esac

    if [ "$node" = qnap ]; then
      # The QNAP is not managed by us: on = Wake-on-LAN, off = graceful QTS
      # shutdown over its existing admin SSH key, status = ping. It serves the
      # k3s NFS PVCs — an off can wedge NFS-mounting hosts in D-state, so this
      # is deliberately a plain graceful shutdown with no forced power-cut.
      case "$action" in
        on)     wakeonlan -i 192.0.2.255 02:00:00:00:00:01 >/dev/null 2>&1 ;;
        off)    ssh -o BatchMode=yes -o ConnectTimeout=8 admin@192.0.2.65 poweroff >/dev/null 2>&1 ;;
        status) ping -c1 -W1 192.0.2.65 >/dev/null 2>&1 && echo on || echo off ;;
        *) echo "denied: bad action"; exit 1 ;;
      esac
    elif [ -n "$ip" ]; then
      case "$action" in
        on)     bmc "$ip" "$kp" on ;;
        off)    bmc "$ip" "$kp" soft ;;
        status) bmc "$ip" "$kp" status ;;
        *) echo "denied: bad action"; exit 1 ;;
      esac
    else
      case "$node" in vm-02) host=srv-01 ;; *) host=gpu-01 ;; esac
      case "$action" in
        on)     vm "$host" "$node" start ;;
        off)    vm "$host" "$node" shutdown ;;
        status) vm "$host" "$node" domstate ;;
        *) echo "denied: bad action"; exit 1 ;;
      esac
    fi
  '';
in
{
  imports = [ ./jumphost-tools.nix ];

  systemd.tmpfiles.rules = [
    # Replaces the unrunnable Debian binary the home rsync left behind.
    "L+ /opt/scripts/aes_kdf_transform - - - - ${aesKdfTransform}/bin/aes_kdf_transform"
    # weekly-updates.sh's double-trigger flock guard; /run/lock is 755 on
    # NixOS (world-writable on Debian), so the file must pre-exist.
    "f /run/lock/weekly-updates.lock 0644 ludorl82 users -"
  ];

  # The service-key surface, declared (it was imperative on console-vm —
  # the exact lesson of the cloud-01 conversion). The laptop key is declared
  # in the host config.
  users.users.ludorl82.openssh.authorizedKeys.keys = [
    ''command="/opt/scripts/process_keepass.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/opt/scripts/process_keepass_family.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/usr/local/bin/kp-get \"Homelab Backup Passphrase\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/usr/local/bin/kp-get \"Homelab Backup Passphrase\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/usr/local/bin/kp-get \"Homelab Backup Passphrase\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/usr/local/bin/kp-get \"Homelab Backup Passphrase\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/home/ludorl82/scripts/homelab-backup.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/opt/scripts/weekly-updates.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/home/ludorl82/scripts/wan_ip_cloudflare_sync.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/usr/local/bin/kp-get \"Homelab Backup Passphrase\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/usr/local/bin/kp-get \"Homelab Backup Passphrase\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/home/ludorl82/scripts/weekly-iac-updates.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    # Ships ha-01's newest HA backup off-box; see modules/ha-backup.nix
    # for why this is a pull rather than an HA-side push.
    ''command="/run/current-system/sw/bin/ha-backup",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    # Home Assistant fleet power switches — can ONLY run `power-ctl <node> <on|off|status>`
    # (the dispatcher above), nothing else. See modules/jumphost.nix powerCtl.
    ''command="${powerCtl}",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
  ];

  # WAN-IP → Cloudflare list sync, every 10 min (was a console-vm user-crontab
  # line with a PATH= trap — now a timer with an explicit PATH). Idempotent.
  systemd.services.wan-ip-sync = {
    description = "Sync WAN IP to Cloudflare Access IP list";
    serviceConfig = {
      Type = "oneshot";
      User = "ludorl82";
    };
    path = [ pkgs.bash pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.openssh pkgs.awscli2 pkgs.dnsutils kpGet ];
    script = ''
      ${pkgs.bash}/bin/bash /home/ludorl82/scripts/wan_ip_cloudflare_sync.sh
    '';
  };
  # OneDrive sync — moved from console-vm 2026-08-05 (its user-scope service
  # was stopped there before the Pi's conversion). Config + refresh_token +
  # sync_list rode the home rsync (~/.config/onedrive — NEVER remove
  # sync_list, the full-drive trap). Single writer: exactly one host runs
  # this.
  systemd.services.onedrive-sync = {
    description = "OneDrive monitor (jumphost)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "ludorl82";
      Restart = "on-failure";
      RestartSec = 60;
      ExecStart = "${pkgs.onedrive}/bin/onedrive --monitor";
    };
  };

  systemd.timers.wan-ip-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/10";
      AccuracySec = "1min";
    };
  };
}
