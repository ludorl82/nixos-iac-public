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
