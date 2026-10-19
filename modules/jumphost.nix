# The jumphost role — worker2 only, ever. Successor of console-host.nix
# after the 2026-08-07 jumphost/console split: the interactive console
# moved to the coquille VM on bob (console-container.nix); what stays
# here is the service surface other machines depend on, deliberately
# co-located with pfSense + the WAN modem on the survivor OR700:
#   - the forced-command key surface (:22): KeePass pipeline triggers
#     from aws, kp-get passphrase fetches from the whole fleet, the
#     Cronicle backup/weekly/wan-ip/ha-backup entry points
#   - the singletons: onedrive-sync ("exactly one host runs this"),
#     wan-ip-sync
# Single-host import IS the singleton guard — there is no role flag; a
# second importer would double-run OneDrive, so don't.
#
# Out-of-band seeds (beyond jumphost-tools.nix's): /opt/scripts/ and
# ~/scripts/ hold the runtime copies of scripts/jumphost/ and scripts/
# from this repo (source of truth in git since 82b9e07; the forced
# commands still point at the coquille-era absolute paths). Exceptions,
# linked from the store below: aes_kdf_transform and weekly-updates.sh.
{ config, pkgs, lib, ... }:
let
  kpGet = import ./kp-get.nix { inherit pkgs; };

  # The KDF speed-up helper both process_keepass*.py shell out to. It arrived
  # here as a Debian-built dynamic binary rsynced from coquille, which NixOS
  # cannot exec at all (no /lib/ld-linux-aarch64.so.1) — so from the
  # 2026-08-05 cutover until 2026-08-07 every run silently took the
  # pure-Python fallback, ~5.5s instead of ~0.5s per KDF. Built from source
  # here so it survives the next reimage.
  # The weekly run, straight from git. Until 2026-09-27 /opt/scripts held a
  # hand copy from 2026-08-19: the serveur -> stella rename (674e786) never
  # reached it, so that morning it rebooted stella, waited 300 s for a node
  # named "serveur" (NotFound) and stopped the rolling loop — four hosts left
  # with a pending kernel. A symlink into the store cannot drift that way.
  # writeScript because the file is 0644 in git and the forced command execs it.
  #
  # The hand pins (../pins.nix) and the nixpkgs revision of flake.lock are baked
  # in as a JSON file, so the weekly pin check compares against what this
  # commit actually pins — not against what aws happens to run, and not against
  # this Pi's own nixpkgs, which is a different input from the fleet's.
  pinsJson = let
    lock = builtins.fromJSON (builtins.readFile ../flake.lock);
    nixpkgsNode = lock.nodes.${lock.nodes.${lock.root}.inputs.nixpkgs};
  in pkgs.writeText "pins.json" (builtins.toJSON {
    k3s = (import ../pins.nix).k3s.version;
    nvidia = (import ../pins.nix).nvidia.version;
    nixpkgsRev = nixpkgsNode.locked.rev;
  });
  weeklyUpdates = pkgs.writeScript "weekly-updates.sh"
    (builtins.replaceStrings [ "@pinsJson@" ] [ "${pinsJson}" ]
      (builtins.readFile ../scripts/jumphost/weekly-updates.sh));

  aesKdfTransform = pkgs.runCommandCC "aes-kdf-transform" {
    buildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -o $out/bin/aes_kdf_transform ${./aes_kdf_transform.c} -lcrypto
  '';

  # Home Assistant fleet power control. HA's forced-command key can ONLY run
  # this — it reads `<node> <on|off|status|where|move|k3s-on|k3s-off|k3s-status>` from $SSH_ORIGINAL_COMMAND and does
  # nothing else (same shape as stella's arcade-ctl). Supermicro x86 boards go
  # through their BMC (ipmitool, password from kp-get piped via IPMI_PASSWORD —
  # never argv); off is `power soft` (graceful ACPI) so the OS shuts down cleanly
  # and vm-always-on can save coquille. The two VM k3s workers + coquille go
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

    # k3s scheduling, per node (added 2026-10-08 for the HA dashboard toggles):
    #   k3s-status : on = schedulable, off = cordoned
    #   k3s-off    : cordon NOW, then drain in the background (HA's command_line
    #                waits ~15 s; a drain can take minutes). Log:
    #                /tmp/k3s-drain-<node>.log on the jumphost.
    #   k3s-on     : uncordon
    # Guard: k3s-off is refused unless at least 3 OTHER nodes stay Ready and
    # schedulable — a tap on the wrong toggle must not empty the cluster.
    # stella's game mode cordons/uncordons it too; the toggle just shows it.
    case "$action" in
      k3s-on|k3s-off|k3s-status)
        case "$node" in
          aws|bob|luna|ludotheque|stella|encodeur|vega|eventreur|worker1|worker2|worker3|worker4|worker5) ;;
          *) echo "denied: bad node"; exit 1 ;;
        esac
        K="k3s kubectl"
        case "$action" in
          k3s-status)
            u=$($K get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null) || { echo unknown; exit 1; }
            [ "$u" = true ] && echo off || echo on ;;
          k3s-on)
            $K uncordon "$node" 2>&1 | grep -v config.yaml.d ;;
          k3s-off)
            others=$($K get nodes --no-headers 2>/dev/null \
              | awk -v n="$node" '$1 != n && $2 == "Ready" { c++ } END { print c + 0 }')
            if [ "$others" -lt 3 ]; then
              echo "refused: only $others other node(s) Ready and schedulable"; exit 1
            fi
            $K cordon "$node" 2>&1 | grep -v config.yaml.d
            setsid nohup $K drain "$node" --ignore-daemonsets --delete-emptydir-data \
              --timeout=300s >"/tmp/k3s-drain-$node.log" 2>&1 </dev/null &
            echo "draining $node (log: /tmp/k3s-drain-$node.log on worker2)" ;;
        esac
        exit 0 ;;
    esac

    case "$node" in
      bob)       ip=192.0.2.5; kp="X11SRA-RF IPMI (bob)" ;;
      # KeePass titles follow the host: "(stella)" is the NEW X11SRA-RF's BMC
      # since 2026-10-17; luna's entry (ludotheque until 2026-10-18) follows.
      # ludotheque accepted until HA sends the new name.
      luna|ludotheque) ip=192.0.2.6; kp="X11SRA-RF IPMI (luna)" ;;
      # stella = ex-encodeur (X11SRA-RF since 2026-10-17); encodeur accepted
      # until HA sends the new name.
      stella|encodeur) ip=192.0.2.8; kp="X11SRA-RF IPMI (stella)" ;;
      # vega (eventreur until 2026-10-18) sits on an X11SRA WITHOUT a BMC since
      # 2026-10-07; its old X9SCM BMC (.7) went with the board to kiosque.
      # Status and off go over SSH; there is no remote "on".
      vega|eventreur)
        case "$action" in
          status) ssh -o BatchMode=yes -o ConnectTimeout=5 vega true </dev/null >/dev/null 2>&1 && echo on || echo off ;;
          off)    ssh -o BatchMode=yes -o ConnectTimeout=8 vega sudo systemctl poweroff </dev/null >/dev/null 2>&1; echo "powering off vega" ;;
          on)     echo "refused: vega has no BMC, press its power button"; exit 1 ;;
          *)      echo "denied: bad action"; exit 1 ;;
        esac
        exit 0 ;;
      worker3|worker4|worker5|coquille|win11) ip="" ;;
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
      # worker5 (a VM on stella) left this dispatcher when it was retired on
      # 2026-09-26 and came back CPU-only on 2026-10-08. worker4 stays on
      # vega. coquille, win11, worker3 and worker5 are MOVABLE between bob and stella (vm-move, modules/vm-host.nix,
      # since 2026-10-08): their host is looked up on every call, and two
      # more verbs exist for them —
      #   where : bob | stella | "bob -> stella" while a move runs | none
      #   move  : start a live move to the other host, return at once
      # win11 joined on 2026-10-08, when it stopped borrowing arcade1's card
      # (its switch went through stella's arcade-ctl until then).
      on_host() {  # $1 host  $2 command — exit status of the remote command
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" "$2" </dev/null >/dev/null 2>&1
      }
      moving_on() {  # $1 host — a vm-move unit for $node is running there
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" \
          "systemctl list-units --plain --no-legend --state=active 'vm-move-$node-*'" </dev/null 2>/dev/null | grep -q .
      }
      other() { [ "$1" = bob ] && echo luna || echo bob; }
      case "$node" in
        worker4) host=vega ;;
        coquille|win11|worker3|worker5)
          host=""
          for h in bob luna; do
            if on_host "$h" "sudo virsh -c qemu:///system domstate $node | grep -qx running"; then
              host=$h; break
            fi
          done
          if [ -z "$host" ]; then
            for h in bob luna; do
              on_host "$h" "sudo virsh -c qemu:///system dominfo $node" && { host=$h; break; }
            done
          fi ;;
        *) host=bob ;;
      esac
      case "$node:$action" in
        coquille:where|win11:where|worker3:where|worker5:where)
          for h in bob luna; do
            moving_on "$h" && { echo "$h -> $(other "$h")"; exit 0; }
          done
          echo "''${host:-none}" ;;
        coquille:move|win11:move|worker3:move|worker5:move)
          [ -n "$host" ] || { echo "refused: $node runs nowhere"; exit 1; }
          for h in bob luna; do
            moving_on "$h" && { echo "refused: $node is already moving ($h -> $(other "$h"))"; exit 1; }
          done
          ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
            "sudo vm-move --detach $node $(other "$host")" </dev/null 2>&1 | tail -n 1 ;;
        *)
          [ -n "$host" ] || host=bob
          case "$action" in
            on)     vm "$host" "$node" start ;;
            off)    vm "$host" "$node" shutdown ;;
            status) vm "$host" "$node" domstate ;;
            *) echo "denied: bad action"; exit 1 ;;
          esac ;;
      esac
    fi
  '';
in
{
  imports = [ ./jumphost-tools.nix ];

  systemd.tmpfiles.rules = [
    # Replaces the unrunnable Debian binary the home rsync left behind.
    "L+ /opt/scripts/aes_kdf_transform - - - - ${aesKdfTransform}/bin/aes_kdf_transform"
    "L+ /opt/scripts/weekly-updates.sh - - - - ${weeklyUpdates}"
    # weekly-updates.sh's double-trigger flock guard; /run/lock is 755 on
    # NixOS (world-writable on Debian), so the file must pre-exist.
    "f /run/lock/weekly-updates.lock 0644 ludorl82 users -"
  ];

  # The jumphost's OUTBOUND identity.
  #
  # Until 2026-09-22 this host authenticated to the whole fleet with
  # ~/.ssh/id_ed25519 — which was `ludo@laptop-01`, the shared key 068fb42
  # revoked. The declarative half of that revocation worked everywhere at once,
  # and so the jump host lost every destination the moment comin rolled it out:
  # `ssh <host>` from here answered "Permission denied (publickey)" for nine
  # hosts while the fleet itself was perfectly healthy and reachable directly
  # from the console. Every fleet hop in this repo and in the Cronicle jobs is
  # supposed to come through here, so that is the whole surface, and it reads
  # like an outage of the parc rather than of one machine.
  #
  # The key is now this machine's own, generated on it and never copied — the
  # point of 068fb42, applied to the host that revocation forgot. The PRIVATE
  # half is necessarily imperative (~/.ssh/id_ed25519_jumphost, mode 600, out of
  # band like every other secret here); what is declared is that ssh should
  # OFFER it. Both halves of the fix then land with the same merge: the fleet
  # learns to accept the key in the 13 host configs, and this line makes the
  # jumphost present it. IdentityFile directives accumulate rather than
  # override, so the default candidates are untouched.
  programs.ssh.extraConfig = ''
    IdentityFile ~/.ssh/id_ed25519_jumphost
  '';

  # The other half of that surface: who this jumphost is willing to BELIEVE.
  # It was imperative too — a ~/.ssh/known_hosts accumulated by whoever
  # happened to type `ssh` first — and it had the hole documented in power-ctl
  # above: the 2026-09-14 serveur->stella rename left a key for
  # stella.lab.example and none for the bare name, so `ssh stella` from here
  # failed host-key verification while `ssh stella.lab.example` worked. Every
  # fleet hop in this repo and in the Cronicle jobs goes through this host, and
  # most of them dial by short name.
  #
  # Declared, /etc/ssh/ssh_known_hosts covers every user on the box and
  # survives a reimage, which the hand-typed file does not.
  #
  # THIS ADDS NO NEW TRUST. The key below is byte-identical to the one this
  # jumphost already trusted for stella.lab.example (this machine's old name);
  # the entry only teaches it that the short name is the same machine. A host whose key is NOT already
  # anchored somewhere trustworthy does not belong in this list. (worker5, a
  # rebuilt guest with rotated keys and no anchor, was the case in point
  # until its retirement on 2026-09-26.)
  programs.ssh.knownHosts = {
    # stella (ex-encodeur, renamed 2026-10-17): host key unchanged, read on
    # the host and already trusted as encodeur.lab.example by the console and
    # Cronicle; both names until the cleanup.
    stella-ed25519 = {
      hostNames = [ "stella" "stella.lab.example" "encodeur" "encodeur.lab.example" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
    };
    # vega (eventreur until 2026-10-18): host key read on the host 2026-10-18
    # over the console's already-trusted session. Declared because the power
    # switch and worker4's lookups now ssh to "vega", a name nothing knew yet.
    vega-ed25519 = {
      hostNames = [ "vega" "vega.lab.example" "eventreur" "eventreur.lab.example" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
    };
    # luna was stella until 2026-10-16 (same machine, same keys). The
    # stella names are gone: that name will belong to another machine.
    luna-ed25519 = {
      hostNames = [ "luna" "luna.lab.example" "ludotheque" "ludotheque.lab.example" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
    };
    luna-rsa = {
      hostNames = [ "luna" "luna.lab.example" "ludotheque" "ludotheque.lab.example" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example";
    };
  };

  # The service-key surface, declared (it was imperative on coquille —
  # the exact lesson of the aws conversion). The laptop key is declared
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
    # RETIRED 2026-09-16: the `cronicle-iac-updates` key used to be declared
    # here AND on coquille, with the same public half on both. The Cronicle
    # event "Weekly IaC update PRs" dials coquille.lab.example:2222 and nothing
    # else — verified against every event's script, it is the only one that
    # mounts /keys/iac-updates. So this half was reachable by nobody, while
    # its runtime copy of weekly-iac-updates.sh on this host sat at its
    # 2026-07-31 version, four commits behind cp-1 and quietly unrunnable.
    #
    # A second door to the same room is not a spare: it is a door nobody
    # checks. Removing it is the point — the access path that remains is the
    # one that is exercised every week and would be noticed if it broke.
    #
    # If the weekly job ever has to fall back to the jumphost, re-add it here
    # AND point the event at this host; do not leave a key waiting for a day
    # that may not come.
    # Ships automatron's newest HA backup off-box; see modules/ha-backup.nix
    # for why this is a pull rather than an HA-side push.
    ''command="/run/current-system/sw/bin/ha-backup",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    # Home Assistant fleet power switches — can ONLY run `power-ctl <node> <on|off|status>`
    # (the dispatcher above), nothing else. See modules/jumphost.nix powerCtl.
    ''command="${powerCtl}",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
  ];

  # WAN-IP → Cloudflare list sync, every 10 min (was a coquille user-crontab
  # line with a PATH= trap — now a timer with an explicit PATH). Idempotent.
  #
  # It reads the WAN address from router with its OWN key,
  # ~/.ssh/id_ed25519_wanip (imperative, generated here 2026-09-24). Until
  # then it rode the revoked XPS key, the last thing pfSense still accepted it
  # for. pfSense's admin entry pins it: from="192.0.2.132",
  # command="ifconfig mvneta0.4090", no-pty and no forwarding, so a leak can
  # read one interface and nothing else. The script dials -4 to match the pin.
  systemd.services.wan-ip-sync = {
    description = "Sync WAN IP to Cloudflare Access IP list";
    serviceConfig = {
      Type = "oneshot";
      User = "ludorl82";
    };
    # util-linux is here for `logger`, and it is not cosmetic. Every logger
    # call in the script is guarded with `2>/dev/null || true`, so without the
    # binary each one vanished without a trace — and that has been the case
    # for the whole script since this moved off cron, where logger came free
    # with the login PATH. Both the list rewrite and the Access policy repair
    # record their outcome that way. The guard is what made a missing binary
    # look like nothing happening.
    path = [ pkgs.bash pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.openssh pkgs.awscli2 pkgs.dnsutils pkgs.util-linux kpGet ];
    script = ''
      ${pkgs.bash}/bin/bash /home/ludorl82/scripts/wan_ip_cloudflare_sync.sh
    '';
  };
  # OneDrive sync — moved from coquille 2026-08-05 (its user-scope service
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

  # Proves the KeePass WebDAV can still be WRITTEN to. A read-only check on a
  # read-write service proves nothing: an Apache authz pattern stopped matching
  # the atomic-save temp file on 2026-09-05 and every save 403'd for four days
  # while GET kept answering 200, the pod stayed Healthy and ArgoCD stayed
  # Synced. See scripts/webdav_write_canary.sh.
  #
  # It lives HERE, on the jumphost, and not in the cluster: the WebDAV pod is
  # pinned to the aws node, so a cluster-side check would share the fate of
  # what it watches. Kuma 68 is a PUSH monitor for the same reason — silence
  # is itself the alert.
  systemd.services.webdav-write-canary = {
    description = "Prove the KeePass WebDAV still accepts writes";
    serviceConfig = {
      Type = "oneshot";
      User = "ludorl82";
    };
    path = [ pkgs.bash pkgs.curl pkgs.coreutils pkgs.util-linux kpGet ];
    script = ''
      ${pkgs.bash}/bin/bash /home/ludorl82/scripts/webdav_write_canary.sh
    '';
  };
  systemd.timers.webdav-write-canary = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # every 15 min against Kuma's 20 min interval + 2 retries: one missed
      # run is tolerated, a genuinely stopped timer still pages
      OnCalendar = "*:0/15";
      AccuracySec = "1min";
      RandomizedDelaySec = "60";
    };
  };
}
