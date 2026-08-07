# pi-02 as the bastion (bastion's successor) — phase 2 of the
# bastion→pi-02 migration (2026-08-05, see net-cfgs/backlog.md).
# Additive/parallel-run: everything here can coexist with a live bastion;
# the identity cutover (DNS alias, WG peer, bastion host keys, OneDrive)
# is a separate deliberate step.
#
# Out-of-band seeds this module expects:
#   /var/lib/console/env            — PASS=<console user password>
#   /home/ludorl82/…                — rsynced from bastion (repos, .claude,
#                                     .keepass_password, OneDrive keyfile,
#                                     scripts/, cloudflare-iac/, .local)
#   /opt/scripts/                   — rsynced from bastion (KeePass pipeline,
#                                     weekly-updates.sh)
#   docker image console-personal — pulled from docker.lab.example:5000 (the
#                                    save/load seed flow is retired)
{ config, pkgs, lib, ... }:
let
  kpPython = pkgs.python3.withPackages (ps: [ ps.pykeepass ]);
  # Same contract as bastion's /usr/local/bin/kp-get (net-cfgs/credentials.md):
  # fetch the live .kdbx from cloud-01 each call, print ONLY the password field.
  kpGet = pkgs.writeScriptBin "kp-get" ''
    #!${kpPython}/bin/python3
    import os, subprocess, sys, tempfile
    from pykeepass import PyKeePass

    KDBX_REMOTE_HOST = "cloud-01"
    KDBX_REMOTE_PATH = "/opt/keepass/ludovic.kdbx"
    KEYFILE_PATH = os.path.expanduser("~/OneDrive/Documents/Certificats/ludovic-2.key")
    PASSWORD_FILE = os.path.expanduser("~/.keepass_password")

    def fetch_kdbx(local_path):
        result = subprocess.run(
            ["${pkgs.openssh}/bin/ssh", "-o", "ConnectTimeout=5", KDBX_REMOTE_HOST,
             "sudo cat " + KDBX_REMOTE_PATH],
            capture_output=True, check=True)
        with open(local_path, "wb") as f:
            f.write(result.stdout)

    def main():
        if len(sys.argv) != 2:
            print('usage: kp-get "Entry Title"', file=sys.stderr)
            sys.exit(1)
        title = sys.argv[1]
        with open(PASSWORD_FILE) as f:
            db_password = f.read().strip()
        with tempfile.NamedTemporaryFile(suffix=".kdbx") as tmp:
            fetch_kdbx(tmp.name)
            kp = PyKeePass(tmp.name, password=db_password, keyfile=KEYFILE_PATH)
            entry = kp.find_entries(title=title, first=True)
            if entry is None:
                print("kp-get: no entry titled '%s'" % title, file=sys.stderr)
                sys.exit(1)
            sys.stdout.write(entry.password)

    main()
  '';
in
{
  virtualisation.docker.enable = true;
  users.users.ludorl82.extraGroups = [ "docker" ];

  # The console container: whole-home bind mount, sshd on :2222, docker
  # socket for nested tooling — identical contract to bastion's compose.
  # Memory-limited so a heavy Claude session squeezes zram, not the kubelet
  # (pi-02 keeps its k3s agent role — user decision 2026-08-04).
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.console = {
    # Pulled from the fleet registry (TLS, CA via private-ca.nix) since
    # 2026-08-05 — replaces the hand docker-save/load flow. Runtime never
    # touches the registry: the unit runs `docker run --pull missing`, so
    # the console starts from the local store with the registry/NAS dark
    # (survivor-island requirement). Keep the old
    # `ludorl82/console-personal:latest` local tag as a rollback — same
    # image, don't "clean it up".
    #
    # PINNED BY DIGEST, deliberately. With a `:latest` tag, `--pull missing`
    # would never notice a newer push — the local copy always satisfies it,
    # so the console would run a stale image forever. A digest makes the
    # version explicit in git and turns a new build into a genuinely
    # "missing" image that gets pulled exactly once.
    #
    # Rebuild flow: net-cfgs/console-image-build.md. Nothing automates it,
    # and it ends with a commit updating the digest below. Build NATIVELY on
    # pi-02 — gpu-01 cannot build arm64 (its binfmt handler is P-flag, not F,
    # so emulated RUN steps die; it would silently emit an amd64 image).
    # Digest below: rebuilt natively on pi-02 2026-08-05 (fresh Docker Hub
    # base + current gh/cloud-01/tofu/kubectl). An OCI index — buildkit attaches a
    # provenance attestation manifest alongside the arm64 one.
    #
    # Previous: sha256:864d8920839aa6e64a7c584cd02ddef101092561c5ab27c76cb063657bda4d26
    # (built 2026-07-25). To roll back, put that digest back here — but note
    # it now pulls from the REGISTRY: a push reassigns the local repo-digest,
    # so the old digest under this repo path no longer resolves offline, and
    # it survives only until registry GC. The offline-safe rollback is the
    # legacy local tag, same image:
    #   ludorl82/console-personal@sha256:864d8920839aa6e64a7c584cd02ddef101092561c5ab27c76cb063657bda4d26
    image = "docker.lab.example:5000/console-personal@sha256:6b0f662686f5941fc6263cb0509e1d55327a67fc78f3d1203d2dcad102fabdee";
    ports = [ "2222:22" ];
    volumes = [
      "/home/ludorl82:/home/ludorl82"
      "/var/run/docker.sock:/var/run/docker-host.sock"
    ];
    environmentFiles = [ "/var/lib/console/env" ];
    extraOptions = [ "--memory=2g" "--memory-swap=3g" ];
  };

  # The KeePass pipeline scripts (/opt/scripts/process_keepass*.py, fired
  # by the cloud-01 trigger's forced-command keys) run on the HOST with
  # `#!/usr/bin/env python3` — provide it with their imports.
  environment.systemPackages = [
    kpGet
    # google-api-python-client + google-auth-oauthlib drive the Gmail-filter
    # phase of process_keepass.py (and gmail_bootstrap.py, which mints the
    # per-account tokens). The script guards its google imports and merely
    # logs-and-skips when they are missing, which is exactly how that phase
    # stayed silently dead from the bastion→pi-02 cutover (2026-08-05)
    # until now — the cutover assumed these wheels wouldn't build on aarch64;
    # they come straight from cache.nixos.org.
    (pkgs.python3.withPackages (ps: [
      ps.pykeepass ps.boto3 ps.requests
      ps.google-api-python-client ps.google-auth-oauthlib
    ]))
    # For the restored bastion scripts run via forced-command keys:
    # homelab-backup.sh needs gpg + cloud-01, wan-ip/weekly scripts need awscli.
    pkgs.gnupg
    pkgs.awscli2
    pkgs.jq
  ];
  # The forced-command keys below reference the bastion-era absolute path.
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin/kp-get - - - - ${kpGet}/bin/kp-get"
    # Restored scripts carry #!/bin/bash shebangs from Debian bastion;
    # NixOS only provides /bin/sh (same fix as hosts/cloud-01).
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    # weekly-updates.sh's double-trigger flock guard; /run/lock is 755 on
    # NixOS (world-writable on Debian), so the file must pre-exist.
    "f /run/lock/weekly-updates.lock 0644 ludorl82 users -"
    # process_keepass.py logs here; pre-existed writable on bastion, NixOS
    # must declare it (same lesson as cloud-01's homelab_backup.log).
    "f /var/log/keepass_domain_hash.log 0644 ludorl82 users -"
  ];

  # bastion's service-key surface, declared (they were imperative there —
  # the exact lesson of the cloud-01 conversion). Inert until the callers'
  # DNS/WG target flips here in phase 3; the laptop key is already declared
  # in the host config.
  users.users.ludorl82.openssh.authorizedKeys.keys = [
    ''command="/opt/scripts/process_keepass.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ''command="/opt/scripts/process_keepass_parola.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
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
    ''command="/home/ludorl82/cloudflare-iac/scripts/drift-check.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example cf-drift''
    ''command="/home/ludorl82/scripts/weekly-iac-updates.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    # Ships ha-01's newest HA backup off-box; see modules/ha-backup.nix
    # for why this is a pull rather than an HA-side push.
    ''command="/run/current-system/sw/bin/ha-backup",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
  ];

  # WAN-IP → Cloudflare list sync, every 10 min (was a bastion user-crontab
  # line with a PATH= trap — now a timer with an explicit PATH). Idempotent,
  # safe to double-run during the parallel phase.
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
  # OneDrive sync — moved from bastion 2026-08-05 (its user-scope service
  # was stopped there before the Pi's conversion). Config + refresh_token +
  # sync_list rode the home rsync (~/.config/onedrive — NEVER remove
  # sync_list, the full-drive trap). Single writer: exactly one host runs
  # this.
  systemd.services.onedrive-sync = {
    description = "OneDrive monitor (bastion)";
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
