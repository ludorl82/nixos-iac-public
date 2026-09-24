# The console container — the interactive workspace (Claude Code, repos,
# nested docker builds). Two importers with opposite postures:
#   - console-vm (VM on gpu-01):  autoStart = true, the real console
#   - pi-02 (jumphost):     autoStart = false — the EMERGENCY console,
#     image resident on disk, `systemctl start docker-console` during an
#     outage; pi-02 is the survivor-island host so this is the shell
#     that outlives a house power event.
#
# Out-of-band seeds: /var/lib/console/env (PASS=<console user password>),
# and the home directory itself (S3 tarball + git clones — see
# scripts/seed-console-home.sh).
{ config, pkgs, lib, ... }:
let
  cfg = config.homelab.console;

  # Lives in the bind-mounted home, so it outlives both the container and the
  # VM. Written from the host side: /home/ludorl82 is the same directory on
  # both sides of the mount, so there is no need to pipe it through docker.
  manifest = "/home/ludorl82/.claude/console-vm-windows.psv";

  claudeSnapshot = pkgs.writeShellScript "console-claude-snapshot" ''
    docker="${config.virtualisation.docker.package}/bin/docker"
    tmp="${manifest}.new"

    # A container that is down, or a session that never started, must NOT
    # truncate a good snapshot — that would silently discard the very thing
    # this exists to protect. Leave the previous file untouched instead.
    if ! "$docker" exec -u ludorl82 console tmux -L console has-session -t claude 2>/dev/null; then
      exit 0
    fi

    # `|`, not a tab: tmux SANITISES control characters in format output,
    # rendering a real tab as a literal underscore. A tab-separated manifest
    # therefore parses as one field and matches nothing — which is exactly how
    # this failed silently the first time (2026-08-20).
    if ! "$docker" exec -u ludorl82 console tmux -L console list-windows -t claude \
         -F '#{window_name}|#{@claude_session_id}|#{pane_current_path}' > "$tmp" 2>/dev/null; then
      rm -f "$tmp"; exit 0
    fi

    # Drop windows with no recorded id (started by hand, nothing to resume).
    ${pkgs.gnugrep}/bin/grep -P '^[^|]*\|[0-9a-f-]{36}\|' "$tmp" > "$tmp.f" || true
    mv "$tmp.f" "$tmp"
    if [ ! -s "$tmp" ]; then rm -f "$tmp"; exit 0; fi

    ${pkgs.coreutils}/bin/install -m 0600 -o ludorl82 -g users "$tmp" ${manifest}
    rm -f "$tmp"
  '';
in
{
  options.homelab.console = {
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the console container at boot. False = emergency posture: unit declared, image kept resident, started by hand.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.str;
      default = "2g";
      description = "docker --memory for the container.";
    };
    memorySwap = lib.mkOption {
      type = lib.types.str;
      default = "3g";
      description = "docker --memory-swap for the container.";
    };
    image = lib.mkOption {
      type = lib.types.str;
      # The 2026-08-05 arm64 build — pi-02's pin. Overridden per-host so a
      # new digest doesn't restart every console at once (a switch that
      # changes the container definition kills the session running inside).
      default = "docker.lab.example:5000/console-personal@sha256:6b0f662686f5941fc6263cb0509e1d55327a67fc78f3d1203d2dcad102fabdee";
      description = "Console image reference (digest-pinned, see comments below).";
    };
    claudeSession = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open a detached tmux session named `claude` inside the container at boot, running Claude Code with Remote Control. Off by default: pi-02's emergency console must not phone home unasked.";
    };
    stableHostKeys = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Bind-mount /var/lib/console/ssh at /etc/ssh/keys so the container's sshd identity survives image rebuilds (needs an image with the console-entry.sh shim, 2026-08-07+).";
    };
  };

  config = {
    virtualisation.docker.enable = true;
    users.users.ludorl82.extraGroups = [ "docker" ];

    # Whole-home bind mount, sshd on :2222, docker socket for nested
    # tooling — identical contract to console-vm-the-Pi4's compose.
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
      # and it ends with a commit updating the digest below. Build the arm64
      # half NATIVELY on a Pi — gpu-01 cannot build arm64 (its binfmt handler is
      # P-flag, not F, so emulated RUN steps die; it would silently emit an
      # amd64 image). The amd64 half builds natively on gpu-01.
      #
      # Previous: sha256:864d8920839aa6e64a7c584cd02ddef101092561c5ab27c76cb063657bda4d26
      # (built 2026-07-25). To roll back, put that digest back here — but note
      # it now pulls from the REGISTRY: a push reassigns the local repo-digest,
      # so the old digest under this repo path no longer resolves offline, and
      # it survives only until registry GC. The offline-safe rollback is the
      # legacy local tag, same image:
      #   ludorl82/console-personal@sha256:864d8920839aa6e64a7c584cd02ddef101092561c5ab27c76cb063657bda4d26
      image = cfg.image;
      ports = [ "2222:22" ];
      volumes = [
        "/home/ludorl82:/home/ludorl82"
        "/var/run/docker.sock:/var/run/docker-host.sock"
      ] ++ lib.optional cfg.stableHostKeys "/var/lib/console/ssh:/etc/ssh/keys:ro";
      environmentFiles = [ "/var/lib/console/env" ];
      extraOptions = [ "--memory=${cfg.memoryLimit}" "--memory-swap=${cfg.memorySwap}" ];
    };

    # Emergency posture: the unit exists (and pulls/keeps the image via its
    # normal preStart when started), but nothing wants it at boot.
    systemd.services.docker-console.wantedBy = lib.mkIf (!cfg.autoStart) (lib.mkForce [ ]);

    # The container's sshd reads ~/.ssh/authorized_keys from the bind-mounted
    # home — a DIFFERENT file from the host sshd's declarative
    # /etc/ssh/authorized_keys.d/ludorl82, and until 2026-08-07 it was
    # imperative, in no repo (the P6 gap). It cannot be a symlink into
    # /etc or /nix/store: neither path exists inside the container. And it
    # cannot be a tmpfiles "C+" copy: on this systemd C+ silently refuses to
    # overwrite an existing file (verified live 2026-08-07). So an activation
    # script installs the host's own merged declared key set on every
    # switch/boot — on pi-02 that is the jumphost service keys + laptop, on
    # console-vm just the console's callers. Ad-hoc key additions no longer
    # survive a switch; declare them in the host config instead.
    # A detached tmux session named `claude`, holding a Claude Code with
    # Remote Control on, so the console is reachable from the phone as soon as
    # the VM is up — no SSH-in-and-start-it step. `partOf` (not just `after`)
    # is what makes an image bump re-create it: restarting the container kills
    # its tmux server, and without the propagation the session would silently
    # not come back.
    #
    # `-L console` on EVERY tmux call, and it is load-bearing. The image's
    # entrypoint starts `tmux -L console new-session -d -s console`, so the
    # socket the interactive console actually uses is the named one; plain
    # `tmux` talks to a SECOND server on /tmp/tmux-1000/default. Getting this
    # wrong is not visibly broken — the session starts and Remote Control
    # works, it is just invisible to `tmux ls` in the console and cannot be
    # attached from there. Worse, the has-session guard then only ever sees the
    # server it created, so it reported "already present" for a session the
    # user could not see (caught live 2026-08-19).
    #
    # Note the HA power switch has two different "on" paths and only one
    # reaches this unit. A cold `virsh start` boots the VM and runs it; a
    # restore from gpu-01's `vm-suspend-console-vm` managedsave (what a weekly
    # -updates reboot of gpu-01 does) resumes RAM, so systemd never re-runs
    # anything — the session is simply still there from before, which is the
    # point of the managedsave. Both paths end with a live `claude` session.
    systemd.services.console-claude-session = lib.mkIf cfg.claudeSession {
      description = "Claude Code with Remote Control, in the console container's `claude` tmux session";
      after = [ "docker-console.service" ];
      requires = [ "docker-console.service" ];
      partOf = [ "docker-console.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Best-effort snapshot on a graceful stop. The timer is what actually
        # makes this survive a crash or a pulled plug — ExecStop never runs
        # then — but on an orderly shutdown it captures the final seconds.
        ExecStop = claudeSnapshot;
      };
      script =
        let docker = "${config.virtualisation.docker.package}/bin/docker";
        in ''
          # Wait until the container is exec-able as ludorl82. NOTHING in the
          # image starts the `-L console` tmux server: the entrypoint is
          # console-entry.sh -> entrypoint.sh -> sshd, and the server only
          # comes to life when a human logs in and tmuxinator attaches. On a
          # cold boot nobody is logged in, so waiting for that server meant
          # waiting forever (2026-08-20: 130 s timeout, no windows restored,
          # every HA button answered "no 'claude' tmux session"). Creating
          # the `claude` session below brings the server up on the SAME named
          # socket (/tmp/tmux-1000/console), which the later interactive
          # login joins — there is no second-server risk on a NAMED socket,
          # only on the default one.
          ready=
          for _ in $(seq 1 60); do
            if ${docker} exec -u ludorl82 console tmux -V >/dev/null 2>&1; then
              ready=1; break
            fi
            sleep 2
          done
          if [ -z "$ready" ]; then
            echo "console container never became exec-able; no claude session started" >&2
            exit 1
          fi

          tm() { ${docker} exec -u ludorl82 console tmux -L console "$@"; }

          # The always-present `backlog` session's id is STABLE — kept in a file
          # in the bind-mounted home — so the backlog conversation is the SAME
          # one across cold boots, even when it has fallen out of the snapshot.
          backlog_id() {
            idfile=/home/ludorl82/.claude/backlog-session-id
            b="$(${docker} exec -u ludorl82 console sh -c "cat $idfile 2>/dev/null")"
            if [ -z "$b" ]; then
              b="$(cat /proc/sys/kernel/random/uuid)"
              ${docker} exec -u ludorl82 console sh -c "umask 077; printf %s '$b' > $idfile"
            fi
            printf %s "$b"
          }
          # --resume when the transcript is on disk, else keep the id but start fresh.
          backlog_mode() {
            if ${docker} exec -u ludorl82 console \
                 find /home/ludorl82/.claude/projects -name "$1.jsonl" -print -quit 2>/dev/null | grep -q .; then
              printf -- '--resume %s' "$1"
            else
              printf -- '--session-id %s' "$1"
            fi
          }
          # Guarantee a `backlog` window with Remote Control on every start.
          # ADDITIVE: it never touches other windows, so it is safe on a session
          # holding live work; and it creates the `claude` session itself when
          # nothing else has (so backlog is the cold-start window).
          ensure_backlog() {
            if tm has-session -t claude 2>/dev/null \
               && tm list-windows -t claude -F '#{window_name}' | grep -qx backlog; then
              echo "backlog window already present"
              return 0
            fi
            bid="$(backlog_id)"
            bcmd="/home/ludorl82/.local/bin/claude $(backlog_mode "$bid") --remote-control backlog"
            if tm has-session -t claude 2>/dev/null; then
              tm new-window -t "claude:" -n backlog -c /home/ludorl82/tmp "$bcmd"
            else
              tm new-session -d -s claude -n backlog -c /home/ludorl82/tmp "$bcmd"
            fi
            tm set-option -w -t "claude:backlog" @claude_session_id "$bid"
            echo "ensured the backlog window (session $bid)"
          }

          # Idempotent: a session that is already there is the desired state and
          # must NOT be replaced — it may be holding live work. Still guarantee
          # the backlog window (additive) before leaving the rest alone.
          if tm has-session -t claude 2>/dev/null; then
            echo "tmux session 'claude' already present, leaving it alone"
            ensure_backlog
            exit 0
          fi

          # Restore from the snapshot if there is one. Each line is
          # name|session-uuid|cwd, written by console-claude-snapshot from live
          # tmux state (`|` because tmux mangles control characters).
          n=0
          if [ -s ${manifest} ]; then
            while IFS='|' read -r wname uuid wcwd; do
              [ -n "$uuid" ] || continue
              [ -n "$wcwd" ] || wcwd=/home/ludorl82/tmp
              # Resume only if the transcript is still on disk; otherwise start
              # a fresh conversation that KEEPS the id, so the window's identity
              # survives even when its history does not.
              if ${docker} exec -u ludorl82 console \
                   find /home/ludorl82/.claude/projects -name "$uuid.jsonl" -print -quit 2>/dev/null | grep -q .; then
                mode="--resume $uuid"
              else
                echo "no transcript for $uuid; starting it fresh under the same id"
                mode="--session-id $uuid"
              fi
              cmd="/home/ludorl82/.local/bin/claude $mode --remote-control $wname"
              n=$((n + 1))
              if [ "$n" -eq 1 ]; then
                tm new-session -d -s claude -n "$wname" -c "$wcwd" "$cmd" || continue
              else
                tm new-window -t "claude:" -n "$wname" -c "$wcwd" "$cmd" || continue
              fi
              tm set-option -w -t "claude:$wname" @claude_session_id "$uuid"
            done < ${manifest}
            echo "restored $n window(s) from the snapshot"
          fi

          # Whatever the restore produced (including nothing), guarantee the
          # always-present backlog window. When nothing was restored this also
          # creates the `claude` session, so backlog IS the cold-start window —
          # no throwaway random-named window any more.
          ensure_backlog
        '';
    };

    # Snapshot the live window list so a COLD boot can rebuild it. A restore
    # from gpu-01's managedsave needs none of this — it resumes RAM — so this
    # exists purely for the real-power-off path.
    #
    # tmux is the source of truth, not a file we maintain alongside it: each
    # window carries its own @claude_session_id, so a window closed by hand
    # simply stops being listed. There is nothing to keep in sync and no drift
    # to reconcile.
    systemd.services.console-claude-snapshot = lib.mkIf cfg.claudeSession {
      description = "Snapshot the console's Claude tmux windows for cold-boot restore";
      serviceConfig = { Type = "oneshot"; ExecStart = claudeSnapshot; };
    };
    systemd.timers.console-claude-snapshot = lib.mkIf cfg.claudeSession {
      description = "Periodic snapshot of the console's Claude tmux windows";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "5min"; };
    };

    systemd.tmpfiles.rules = [
      "d /home/ludorl82/.ssh 0700 ludorl82 users -"
    ];
    system.activationScripts.consoleAuthorizedKeys =
      let
        keysFile = pkgs.writeText "console-authorized-keys"
          (lib.concatStringsSep "\n" config.users.users.ludorl82.openssh.authorizedKeys.keys + "\n");
      in ''
        install -D -m 0600 -o ludorl82 -g users ${keysFile} /home/ludorl82/.ssh/authorized_keys
      '';
  };
}
