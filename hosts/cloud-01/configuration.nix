## NixOS config for cloud-01 - the EC2 instance (t3a.medium, ca-central-1a,
## Elastic IP 203.0.113.7 / VPC 198.51.100.7). Last host of the fleet
## conversion, and the highest-stakes one: it is the SOLE k3s
## control-plane + etcd member, and the WireGuard hub to the homelab.
##
## It ran the KeePass WebDAV / Uptime Kuma / ntfy docker stacks until they
## migrated into k3s (kuma+ntfy 2026-07-25, webdav 2026-08-06). No docker
## compose stack remains, and as of 2026-08-07 nothing of ours lives under
## /var/lib/docker any more either (the KeePass data moved to /var/lib/keepass).
## docker stays enabled only for ad-hoc use and the three archived volumes.
## It does still host the k3s pods for all three, pinned back onto this node.
##
## Conversion notes:
##   - UEFI-booted (boot mode uefi-preferred). canTouchEfiVariables stays
##     false: systemd-boot's fallback copy at \EFI\BOOT\BOOTX64.EFI is what
##     the firmware finds, no dependency on efivar persistence across
##     stop/start.
##   - The security perimeter is the EC2 security group (22 from home WAN
##     only, k3s/etcd ports from the VPC, 51820/udp open); the old Ubuntu
##     had no host firewall (no ufw, INPUT ACCEPT), so the NixOS firewall
##     stays off to match - turning it on would be a new failure mode for
##     flannel-over-wg, docker DNAT and the wg-quick PostUp routing.
##   - State restored out-of-band via nixos-anywhere --extra-files (never
##     in git): /var/lib/rancher/k3s/server (etcd + token + TLS CA - loss
##     means re-joining all 8 agents), /etc/wireguard/wg0.key,
##     /etc/credstore/*.cred + /var/lib/systemd/credential.secret (the
##     systemd-creds host key - the .cred files are useless without it),
##     /root/.ssh (keepass trigger + nas pull keys),
##     /home/ludorl82/*-docker compose dirs (.env secrets), and the docker
##     volume data (keepass2-home, kuma-data, ntfy-data,
##     traefik-letsencrypt).
##
##     /opt/scripts came OFF this list on 2026-08-08: all six scripts are
##     declared below and symlinked in from the store, so the directory no
##     longer holds anything a restore has to bring back. Its .bak files are
##     not state -- git is.
{ config, pkgs, lib, ... }:
let
  # /opt/scripts (frigate S3 sync, keepass backup/process) need these;
  # scripts use `#!/usr/bin/env python3`.
  pyEnv = pkgs.python3.withPackages (ps: with ps; [ boto3 requests pykeepass ]);
  # The two Frigate S3 sync scripts, declared rather than left as restored
  # /opt/scripts files -- see the systemd units below for why. They carry
  # their Kuma push tokens inline; that is deliberate and matches the same
  # tokens already living in k3s-iac's drift/backup manifests. The tokens are
  # write-only heartbeat endpoints (they can forge an up/down beat, they can
  # read nothing), this repo is private, and sanitize-public.sh redacts them
  # from the public snapshot. Move them to /etc/credstore if that calculus
  # ever changes.
  syncFrigateSnapshots = ./scripts/sync_frigate_snapshots.py;
  syncFrigateLowres = ./scripts/sync_frigate_lowres.py;
  # The remaining /opt/scripts files, declared 2026-08-08 for the same reason
  # the two above were in 2026-07-26 -- they existed only on the running host,
  # so a reinstall would have produced working forced-command keys and units
  # pointing at nothing. The trigger this time was a real outage: an edit to
  # homelab-backup.py left a root-owned mode-751 .bak beside it, and since
  # that script tars /opt/scripts wholesale while running as ludorl82, the
  # nightly backup died on the unreadable file (see net-cfgs history
  # 2026-08-08). Symlinking these from the store also ends the habit that
  # caused it: there is no reason to keep a .bak in a directory whose
  # history is now in git.
  #
  # homelab-backup.py and process_keepass.sh are invoked BY PATH (the
  # forced-command key and the keepass-watch unit respectively), so both
  # need their executable bit -- it is set on the files in this repo and
  # Nix preserves it into the store. The other two are always invoked as
  # `python3 <path>`, so they do not.
  homelabBackup = ./scripts/homelab-backup.py;
  backupKeepass = ./scripts/backup_keepass.py;
  processKeepassPy = ./scripts/process_keepass.py;
  processKeepassSh = ./scripts/process_keepass.sh;
  # The KeePass database directory: what the sync trigger watches, what the
  # k3s webdav pod hostPath-mounts, and what /opt/keepass symlinks to.
  #
  # Moved here 2026-08-07 from
  # /var/lib/docker/volumes/numeriseur-docker_keepass2-home/_data — a docker
  # volume that belonged to the numeriseur compose stack, then to web-docker,
  # and finally (once the keepass-webdav tunnel was retired) to no compose
  # stack at all, on a host running no docker stacks. The name had stopped
  # describing anything true. Done as its own change, with the pod scaled to
  # zero and this watcher stopped, because six things pointed at that path —
  # including /opt/scripts/backup_keepass.py, which is invoked by a Cronicle
  # forced-command key and is NOT in this repo.
  keepassVolume = "/var/lib/keepass";
  # Replaces incron -- see the keepass-watch unit below for why. One
  # long-lived inotifywait, never forks, so there is no exec-failure path
  # that can leave a duplicate watcher behind.
  keepassWatch = pkgs.writeShellScript "keepass-watch" ''
    set -u
    while [ ! -d "${keepassVolume}" ]; do sleep 5; done
    # ^ the tmpfiles `d` rule below creates this directory, so on a normal
    # boot it is already there. The loop stays as the guard for a restore
    # that has not landed yet.
    # close_write catches a direct write, moved_to the atomic temp-file
    # rename a KeePass save over davfs actually produces. Dispatch is
    # sequential on purpose: one save emits 3-4 events in quick succession
    # and running them one at a time keeps a burst from fanning out.
    # process_keepass.sh's own `case` decides which filenames matter and its
    # flock guards against overlapping a manual run. It exits 1 even on
    # success (its last command is the `[[ $rc -ne 0 ]] &&` alert guard), so
    # the exit code is deliberately ignored.
    inotifywait -m -q -e close_write -e moved_to --format '%f' "${keepassVolume}" |
      while read -r changed; do
        /opt/scripts/process_keepass.sh "$changed" || true
      done
  '';
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/private-ca.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  # EC2 serial console output - the only "monitor" this box will ever have.
  boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty1" ];

  networking.hostName = "cloud-01";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.firewall.enable = false; # SG is the perimeter - see header
  # DHCP from the VPC: v4 hands out 198.51.100.7 (primary ENI IP, immutable),
  # v6 the ::7 (hex convention, assigned on the ENI). Route + DNS come from
  # the VPC too.
  systemd.network = {
    enable = true;
    networks."10-wan" = {
      matchConfig.Name = "ens5";
      networkConfig = { DHCP = "yes"; IPv6AcceptRA = true; };
      # Keep our hostname, don't let the VPC DHCP rename us to ip-10-10-10-7.
      dhcpV4Config.UseHostname = false;
    };
  };
  services.resolved.enable = true; # wg-quick PostUp below routes homelab domains

  # WireGuard hub to the homelab (peer = router). Same wg-quick shape as
  # the old /etc/wireguard/wg0.conf: the PostUp pins the 192.0.2.0/23 route
  # with src 198.51.100.7 (so k3s/flannel traffic to the homelab sources from
  # the node IP, not 198.18.0.2), and routes homelab DNS zones at pfSense.
  # Private key restored out-of-band to /etc/wireguard/wg0.key (0600 root).
  networking.wg-quick.interfaces.wg0 = {
    address = [ "198.18.0.2/30" ];
    listenPort = 51820;
    privateKeyFile = "/etc/wireguard/wg0.key";
    postUp = ''
      ip route replace 192.0.2.0/23 dev wg0 scope link src 198.51.100.7
      resolvectl dns wg0 192.0.2.254
      resolvectl domain wg0 '~lab.example' '~example.com' '~family.example'
      resolvectl default-route wg0 false
    '';
    preDown = "resolvectl revert wg0";
    peers = [
      {
        publicKey = "bLBOHha9tqGJTVGOUKWACJf31LezMLQJPhN1ETXLtCs=";
        allowedIPs = [ "198.18.0.1/32" "192.0.2.0/23" "203.0.113.0/23" ];
        persistentKeepalive = 25;
      }
    ];
  };

  # k3s server: sole control-plane + etcd member. The restored
  # /var/lib/rancher/k3s/server carries the cluster identity (etcd db,
  # token, TLS CA) so agents rejoin without any re-registration. No
  # --server flag: the old Ubuntu unit still pointed at the long-dead
  # cp-3 (join-time artifact) - deliberately not carried over.
  # k3s: the SOLE control-plane node, so this is the one that must be upgraded
  # FIRST — an agent newer than its server is the unsupported direction.
  #
  # History worth keeping, because this line has been both things: it was a
  # hand-rolled fetchurl on the belief that nixpkgs topped out at 1.35.6, and
  # that premise was wrong — `pkgs.k3s_1_36` was the same 1.36.2+k3s1,
  # properly packaged, all along. It moved there on 2026-07-24.
  #
  # 2026-08-09 it moved back, for a reason the first round did not have:
  # upstream stable is 1.36.3+k3s1 and nixpkgs still packages 1.36.2 at that
  # attribute (verified against the cp-1 lock, PR #7's lock, and unstable
  # HEAD — and there is no k3s_1_37). The attribute can no longer express the
  # version the cluster runs. modules/k3s-upstream.nix is shared with every
  # agent, so the fleet still runs one version from one definition, and that
  # file says to delete it the moment nixpkgs catches up.
  services.k3s = {
    enable = true;
    package = pkgs.callPackage ../../modules/k3s-upstream.nix { };
    role = "server";
    extraFlags = [
      "--node-ip=198.51.100.7"
      "--node-taint=dedicated=controlplane:NoSchedule"
    ];
  };

  # Docker stacks (compose files + .env live in /home/ludorl82/<dir>,
  # restored as-is). Containers are `restart: unless-stopped` so dockerd
  # itself revives them on boot; these oneshots are the declarative glue
  # that (re)creates them from compose on first boot / after changes.
  virtualisation.docker.enable = true;

  # compose-web removed 2026-08-06 — the last docker stack on this host is
  # gone, and with it the last Cloudflare tunnel connector living outside the
  # cluster. It ran traefik + the webdav httpd + a second cloudflared for the
  # `keepass-webdav` tunnel (2fef02a3). Its five hostnames now ride the `k3s`
  # tunnel: router/ha-01/plex route to their origins, vault.family.example is
  # served by a k3s Deployment pinned to this node (k3s-iac keepass-webdav/),
  # and traefik.pub.example.com was retired outright. The compose dir and the docker
  # volume stay on disk, same archive convention as ntfy/kuma below.
  #
  # webdav-lockout removed in the same pass. It tailed traefik's json access
  # log and, on 15 failed auths in 180s, moved webdav.yml out of the dynamic
  # dir so the router vanished, alerting via ntfy and requiring a manual
  # webdav-unlock.sh. Both halves of that — the log it read and the file it
  # moved — belonged to the traefik container. Rather than port it, the
  # decision (2026-08-06) was to rely on the Cloudflare edge, which already
  # fronts this hostname: a Canada-only geo-block and a 20-req/10s rate limit,
  # both in cloudflare-iac live/rulesets.tf, on top of the bcrypt basic auth
  # now enforced by an in-cluster Traefik Middleware. Understand what that
  # trades away: the edge throttles and filters, but nothing now makes the
  # doorway disappear under a sustained attack, and nothing pages you when one
  # happens. If that backstop is wanted again it belongs in-cluster, driven by
  # Loki (Alloy already ships Traefik's logs) and patching the IngressRoute.
  #
  # compose-ntfy / compose-kuma removed 2026-07-25: both migrated to k3s
  # (namespaces `ntfy`/`kuma`, pods pinned back onto this node, local-path
  # PVCs). Kuma's old 198.51.100.7:3001 push endpoint is preserved by a
  # hostPort on the k3s deployment - resurrecting the docker container here
  # would fight it for the port. The compose dirs and docker volumes stay
  # on disk as an archive only.

  # KeePass sync trigger: a save landing in the webdav volume fires
  # process_keepass.sh, which pokes console-vm over the wg tunnel (see memory:
  # keepass sync pipeline). Runs as root - the script uses /root/.ssh keys
  # + /etc/credstore.
  #
  # Was `services.incron` (and ludorl82's incrontab before the conversion)
  # until 2026-07-27. incron 0.5.12 leaks copies of its own daemon: when its
  # fork-for-exec fails ("cannot exec process: Resource temporarily
  # unavailable") the child re-enters the main event loop instead of
  # exiting, still holding the parent's inotify fd. Those copies then race
  # the parent to read events, so an arbitrary subset of saves gets consumed
  # by a copy that never runs the command. The failure is silent and
  # partial: the .kdbx still lands on disk correctly, incron still logs
  # *some* events, and only the ones that matter go missing. Found with 34
  # leaked children (oldest dating to the conversion itself); restarting the
  # unit clears them but 4 more accumulated within a minute, so this was a
  # standing re-break, not a one-off. incrond also core-dumps in
  # free_tables() on shutdown.
  #
  # A plain systemd .path unit is NOT a substitute here: PathChanged /
  # PathModified map to IN_CLOSE_WRITE only, and a KeePass save over davfs
  # lands as an atomic rename - IN_MOVED_TO - which is exactly the event
  # that has to fire.
  systemd.services.keepass-watch = {
    description = "Watch the KeePass WebDAV volume, fire the sync pipeline";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" "network-online.target" ];
    # process_keepass.sh needs bash/coreutils, ssh for the trigger hop to
    # console-vm, flock from util-linux, and curl + systemd-creds for the ntfy
    # failure alert. Same set the old incron extraPackages carried.
    path = [ pkgs.inotify-tools pkgs.bash pkgs.coreutils pkgs.curl pkgs.openssh pkgs.util-linux pkgs.systemd ];
    serviceConfig = {
      ExecStart = "${keepassWatch}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Frigate snapshot S3 archive syncs, hourly at :30/:45 (were ludorl82's
  # sudo crontab entries). Run as root: they use /root/.ssh/id_ed25519_nas_pull
  # for the rsync pull and the instance role (RoleAws) for S3. Log paths
  # preserved from the cron redirections.
  #
  # The scripts themselves live in hosts/cloud-01/scripts/ and are symlinked into
  # /opt/scripts by the tmpfiles rules below. They were undeclared until
  # 2026-07-26: the units and the Cronicle forced-command keys were in git but
  # the .py files existed only on the running host, so a reinstall would have
  # produced working timers pointing at nothing (same class of gap as the
  # /opt/keepass symlink this conversion already lost once). ExecStart points
  # at the store path directly; the /opt/scripts symlinks exist for the
  # forced-command keys further down, which invoke them by absolute path.
  systemd.services.frigate-snapshot-sync = {
    description = "Pull Frigate snapshots from nas, archive to S3";
    path = [ pkgs.rsync pkgs.openssh ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pyEnv}/bin/python3 ${syncFrigateSnapshots}";
      StandardOutput = "append:/var/log/frigate_snapshot_sync.log";
      StandardError = "append:/var/log/frigate_snapshot_sync.log";
    };
  };
  systemd.timers.frigate-snapshot-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* *:30:00"; Persistent = false; };
  };
  systemd.services.frigate-lowres-sync = {
    description = "Pull Frigate low-res clips from nas, archive to S3";
    path = [ pkgs.rsync pkgs.openssh ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pyEnv}/bin/python3 ${syncFrigateLowres}";
      StandardOutput = "append:/var/log/frigate_lowres_sync.log";
      StandardError = "append:/var/log/frigate_lowres_sync.log";
    };
  };
  systemd.timers.frigate-lowres-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* *:45:00"; Persistent = false; };
  };

  # The restored /opt/scripts shell scripts carry #!/bin/bash shebangs from
  # Ubuntu; NixOS only provides /bin/sh by default. Cheaper to provide the
  # path than to patch every restored script (and their .bak history).
  #
  # /opt/keepass: stable path into the keepass webdav volume - console-vm's
  # kp-get does `ssh cloud-01 sudo cat /opt/keepass/ludovic.kdbx` (contract in
  # net-cfgs/credentials.md). Existed as an undeclared symlink on Ubuntu
  # and was lost in the conversion; now declarative so it survives both
  # reboots and reinstalls.
  #
  # ${keepassVolume} must be owned by 1006:1006 - the k3s webdav pod runs
  # with `runAsUser/runAsGroup: 1006` (it inherited the uid from the docker
  # container it replaced on 2026-08-06), so a root-owned directory means
  # mod_dav can't create the `.kdbx.tmp` file a KeePass save writes first:
  # every save 500s while GETs still work, i.e. the DB silently goes
  # read-only. The NixOS conversion restored the data as root:root and did
  # exactly that.
  #
  # `d` then `Z`, both, and the pairing matters. When this lived under a
  # docker volume path only `Z` was safe - `d` would have pre-created the
  # directory on a fresh install, and the k3s pod's `hostPath: type:
  # Directory` would then have mounted an EMPTY directory instead of failing,
  # i.e. served an empty DB rather than refusing to start. Now that the path
  # is ours, `d` is the right call: it makes the directory declarative (so
  # keepass-watch's wait loop and the pod's mount both have something to bind
  # to on first boot), while `Z` still fixes ownership recursively on the
  # restored .kdbx files, which `d` alone does not touch.
  systemd.tmpfiles.rules = [
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    "L+ /opt/keepass - - - - ${keepassVolume}"
    "d ${keepassVolume} 0755 1006 1006 -"
    "Z ${keepassVolume} - 1006 1006 -"
    # homelab-backup.py runs as ludorl82 (Cronicle SSH) and logs here; on
    # Ubuntu the file pre-existed writable, NixOS has to declare it.
    "f /var/log/homelab_backup.log 0644 ludorl82 users -"
    # The Cronicle forced-command keys below invoke these by absolute path,
    # so the /opt/scripts names have to keep resolving. `L+` replaces whatever
    # the conversion restored there with the store path, so the running copy
    # can never drift from git again.
    "L+ /opt/scripts/sync_frigate_snapshots.py - - - - ${syncFrigateSnapshots}"
    "L+ /opt/scripts/sync_frigate_lowres.py - - - - ${syncFrigateLowres}"
    "L+ /opt/scripts/homelab-backup.py - - - - ${homelabBackup}"
    "L+ /opt/scripts/backup_keepass.py - - - - ${backupKeepass}"
    "L+ /opt/scripts/process_keepass.py - - - - ${processKeepassPy}"
    "L+ /opt/scripts/process_keepass.sh - - - - ${processKeepassSh}"
  ];

  # uid pinned to the Ubuntu value so the restored /home/ludorl82 and
  # docker socket work unchanged. (The webdav volume's uid 1006 is a
  # container-internal uid, not a host account - deliberately no user here,
  # it's enforced as numeric ownership by the tmpfiles `Z` rule above.)
  users.users.ludorl82 = {
    isNormalUser = true;
    uid = 1001;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      # Cronicle service keys (forced-command), declared here so sshd's
      # strict-modes check on the home file can never break them again --
      # the 2026-07-26 backup outage was exactly that (extra-files restore
      # left ~/.ssh/authorized_keys group-writable; sshd refused the file).
      ''command="sudo sh -c 'python3 /opt/scripts/backup_keepass.py >> /var/log/keepass_backup.log 2>&1'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      ''command="sudo sh -c 'python3 /opt/scripts/sync_frigate_lowres.py >> /var/log/frigate_lowres_sync.log 2>&1'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      ''command="sudo sh -c 'python3 /opt/scripts/sync_frigate_snapshots.py >> /var/log/frigate_snapshot_sync.log 2>&1'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      ''command="/opt/scripts/homelab-backup.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # gnupg: /opt/scripts/homelab-backup.py streams its tar through
  # `gpg --symmetric` before the S3 upload.
  environment.systemPackages = [ pyEnv pkgs.rsync pkgs.curl pkgs.docker-compose pkgs.wireguard-tools pkgs.gnupg ];

  system.stateVersion = "26.05";
}
