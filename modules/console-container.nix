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

  # ---- The lab's OBSERVER: OpenCode (since 2026-09-27; was Qwen Code) ----
  #
  # OpenCode runs as a SERVER inside the container (`opencode serve`, tmux
  # window observateur:gaming-01); the terminal (`opencode attach`), the office voice
  # and the Home Assistant app all talk to that one server, through the hub on
  # the host. Why OpenCode rather than Qwen Code: a real client/server API
  # (sessions, event stream, permission replies) instead of mirroring a TUI
  # through files, and any OpenAI-compatible provider per request — the way
  # out when Alibaba's content filter refuses a turn.
  #
  # OBSERVER, not operator (Ludo, 2026-09-26): it reads the whole lab, helps
  # think, and writes ONLY to the backlog (labo-backlog). Changes are Claude's.
  # Enforced by the system: kubectl with the read-only ServiceAccount
  # (k3s-iac qwen-readonly) and hosts only through labo-lire's allowlist.
  # Enforced by OpenCode's rules below: every edit denied, shell writes and
  # everything that changes things denied (not asked — there is nothing to
  # approve). OpenCode matches the command line literally, so `git -C x
  # commit` needs its own pattern: seen letting a commit through on 2026-09-27.
  opencodeVersion = "1.18.32";
  opencodeConfig = pkgs.writeText "opencode.json" (builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    autoupdate = false;
    share = "disabled";
    # Muse Spark 1.3, CONTRIBUTOR tier (Ludo, 2026-09-27): $0.10 / $0.20 per
    # million tokens, about 12x under the standard tier — because Meta may
    # train on the prompts and completions. The observer sends the lab's
    # memory, configuration and command output; that trade was chosen
    # knowingly. The standard tier (meta/muse-spark-1.3) does not train.
    # Alibaba (qwen3.8-flash) is gone, and with it the content filter that
    # kept refusing whole conversations.
    provider.openrouter = {
      options.apiKey = "{env:OPENROUTER_API_KEY}";
      models."meta/muse-spark-1.3-contributor" = { };
    };
    model = "openrouter/meta/muse-spark-1.3-contributor";
    # ONE source of instructions for Claude and the observer: Claude's memory
    # index, kept current by every Claude session.
    instructions = [ "/home/ludorl82/.claude/projects/-home-ludorl82-tmp/memory/MEMORY.md" ];
    default_agent = "observateur";
    agent.observateur = {
      mode = "primary";
      description = "Lit tout le labo, aide à réfléchir, n'écrit que dans le backlog";
      prompt = "{file:/home/ludorl82/.local/share/qwen-voice/observateur.md}";
      permission = {
        edit = "deny";
        webfetch = "allow";
        external_directory = "allow";
        read = {
          "*" = "allow";
          "/home/ludorl82/.ssh/**" = "deny";
          "/home/ludorl82/.kube/**" = "deny";
          "/home/ludorl82/.config/**" = "deny";
          "/home/ludorl82/.local/state/qwen-voice/**" = "deny";
        };
        # Order matters: "*" first, the specific rules after it win.
        bash = { "*" = "allow"; } // builtins.listToAttrs (map (c: { name = c; value = "deny"; }) [ "ssh *" "scp *" "sftp *" "rsync *" "sudo *" "su *" "doas *" "kp-get *" "* kp-get *" "*qwen-voice*" "*opencode-password*" "python *" "python3 *" "node *" "perl *" "ruby *" "bash -c *" "sh -c *" "zsh -c *" "eval *" "xargs *" "find * -exec *" "find * -delete*" "env *" "npx *" "npm *" "opencode *" "rm *" "rmdir *" "mv *" "cp *" "ln *" "touch *" "mkdir *" "tee *" "dd *" "shred *" "truncate *" "install *" "chmod *" "chown *" "sed -i*" "sed * -i*" "perl -i*" "crontab *" "* > *" "* >> *" "*>/*" "*>>/*" "git * add *" "git add *" "git * commit *" "git commit *" "git * push *" "git push *" "git * reset *" "git reset *" "git * checkout *" "git checkout *" "git * switch *" "git switch *" "git * restore *" "git restore *" "git * merge *" "git merge *" "git * rebase *" "git rebase *" "git * cherry-pick *" "git cherry-pick *" "git * revert *" "git revert *" "git * stash *" "git stash *" "git * clean *" "git clean *" "git * rm *" "git rm *" "git * mv *" "git mv *" "git * tag *" "git tag *" "git * apply *" "git apply *" "git * am *" "git am *" "git * worktree *" "git worktree *" "git * config *" "git config *" "git * remote *" "git remote *" "git * branch -d*" "git branch -d*" "git * branch -D*" "git branch -D*" "git * init*" "git init*" "git * clone *" "git clone *" "gh *" "kubectl * --kubeconfig*" "kubectl --kubeconfig*" "KUBECONFIG=*" "kubectl config *" "curl * -X POST*" "curl * -X PUT*" "curl * -X PATCH*" "curl * -X DELETE*" "curl * -XPOST*" "curl * --request *" "curl * -d *" "curl * --data*" "curl * -F *" "curl * --form*" "curl * -T *" "curl * --upload-file*" "wget * --post*" "wget * --method*" "systemctl start *" "systemctl stop *" "systemctl restart *" "systemctl reload *" "systemctl enable *" "systemctl disable *" "systemctl mask *" "systemctl kill *" "systemctl daemon-reload*" "systemctl edit *" "systemctl isolate *" "reboot*" "shutdown*" "poweroff*" "halt*" "docker run *" "docker exec *" "docker rm *" "docker rmi *" "docker stop *" "docker kill *" "docker restart *" "docker start *" "docker create *" "docker build *" "docker push *" "docker compose *" "docker system *" "docker volume *" "docker network *" "docker cp *" "docker update *" "docker commit *" "docker tag *" "docker login *" "virsh *" "helm *" "tofu *" "terraform *" "nixos-rebuild *" "nix-env *" "nix profile *" "nix-collect-garbage*" "home-manager *" "tmux *" ]);
      };
    };
  });
  observerPrompt = pkgs.writeText "observateur.md" ''
    Tu es l'observateur du labo de Ludo. Tu lis tout (cluster, hôtes, dépôts,
    docs, mémoire) et tu l'aides à réfléchir. Tu ne modifies JAMAIS le labo :
    les changements sont faits par Claude. Ta seule écriture permise est une
    entrée au backlog, avec `labo-backlog "Titre" "détails"`.
    Pour l'état actuel, vérifie avec une commande plutôt que de mémoire :
    `labo-alertes`, `labo-sante`, `kubectl get/describe/logs` (lecture seule),
    et `labo-lire <hôte> <commande>` pour les hôtes (ssh direct refusé).
    Évite les redirections du shell (`>`), refusées.
  '';
  # The server, in tmux window observateur:gaming-01. Keys live only in this process's
  # environment; the server password is created by the hub on the host (same
  # file, bind-mounted) and is unreadable to the agent.
  opencodeServe = pkgs.writeText "opencode-serve.sh" ''
    #!/bin/bash
    set -uo pipefail
    state="$HOME/.local/state/qwen-voice"
    kp() { ssh -4 -n -o BatchMode=yes pi-02.lab.example "kp-get \"$1\""; }
    if ! OPENCODE_SERVER_PASSWORD=$(cat "$state/opencode-password") || ! OPENROUTER_API_KEY=$(kp "OpenRouter API Key"); then
      echo "opencode-serve : mot de passe ou clé introuvable ; relance le hub (qwen-voice-bridge)." >&2
      exec sleep infinity
    fi
    export OPENCODE_SERVER_PASSWORD OPENROUTER_API_KEY
    # kubectl for the agent = the read-only ServiceAccount (k3s-iac
    # qwen-readonly), built with the admin kubeconfig it cannot read. Without
    # the token, kubectl gets an empty config: failing closed.
    kc="$state/kubeconfig"
    ( umask 077
      tok=$(kubectl -n qwen-readonly get secret qwen-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
      srv=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
      ca=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null)
      if [ -n "$tok" ] && [ -n "$srv" ]; then
        printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: labo\n  cluster:\n    server: %s\n    certificate-authority-data: %s\nusers:\n- name: qwen\n  user:\n    token: %s\ncontexts:\n- name: qwen\n  context: {cluster: labo, user: qwen}\ncurrent-context: qwen\n' "$srv" "$ca" "$tok" > "$kc"
      else
        echo "opencode-serve : pas de jeton qwen-readonly ; kubectl désactivé." >&2
        : > "$kc"
      fi )
    export KUBECONFIG="$kc" OPENCODE_CONFIG="$HOME/.local/share/qwen-voice/opencode.json" OPENCODE_DISABLE_AUTOUPDATE=1
    mkdir -p "$HOME/observateur" && cd "$HOME/observateur"
    # 0.0.0.0 inside the container: the hub reaches it over the docker bridge
    # (no published port, so no container re-creation); the password guards it.
    exec "$HOME/.local/bin/opencode" serve --hostname 0.0.0.0 --port 4096
  '';
  # A plain interactive Qwen Code in tmux session `qwen`, beside
  # `observateur` and `claude` (Ludo, 2026-09-27): for the NIGHT JOBS — rerun,
  # debug, adjust what they do — on the model they use (qwen3.8-flash,
  # Alibaba). The jobs themselves run headless from Cronicle with their own
  # HOME (~/.config/qwen-pipeline) and do not need this. No voice, no hub:
  # every command and edit waits for a keypress (--approval-mode default).
  qwenInteractiveSettings = pkgs.writeText "qwen-settings.json" (builtins.toJSON {
    general.disableAutoUpdate = true;
    privacy.usageStatisticsEnabled = false;
    context = {
      fileName = [ "QWEN.md" "AGENTS.md" "CLAUDE.md" "MEMORY.md" ];
      includeDirectories = [ "/home/ludorl82/.claude/projects/-home-ludorl82-tmp/memory" ];
      loadFromIncludeDirectories = true;
    };
  });
  qwenInteractive = pkgs.writeText "qwen-interactive.sh" ''
    #!/bin/bash
    set -uo pipefail
    if ! key="$(ssh -4 -n -o BatchMode=yes pi-02.lab.example 'kp-get "Alibaba Cloud API Key"')" || [ -z "$key" ]; then
      echo "qwen : clé Alibaba introuvable (kp-get via pi-02)." >&2; exec sleep infinity
    fi
    export OPENAI_API_KEY="$key" QWEN_CODE_TELEMETRY_DISABLED=1
    export QWEN_CODE_SYSTEM_SETTINGS_PATH="$HOME/.local/share/qwen-voice/qwen-settings.json"
    cd "$HOME/git/ludorl82/nixos-iac" 2>/dev/null || cd "$HOME"
    exec "$HOME/.local/bin/qwen" --continue --auth-type openai \
      --openai-base-url https://dashscope-intl.aliyuncs.com/compatible-mode/v1 \
      -m qwen3.8-flash --approval-mode default
  '';
  # One terminal window per session: a client of the same server.
  opencodeAttach = pkgs.writeText "opencode-attach.sh" ''
    #!/bin/bash
    export OPENCODE_SERVER_PASSWORD=$(cat "$HOME/.local/state/qwen-voice/opencode-password")
    cd "$HOME/observateur" && exec "$HOME/.local/bin/opencode" attach http://127.0.0.1:4096 --session "$1"
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
    qwenSession = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open a detached tmux session named `qwen` next to `claude`, running Qwen Code (qwen3.8-flash on Alibaba Model Studio) with dual-output channels so the voice bridge can share its conversation.";
    };
    qwenVoiceBridge = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Serve the `qwen` session to Home Assistant's Ollama integration (scripts/qwen-voice-bridge.py). Needs qwenSession.";
      };
      listen = lib.mkOption { type = lib.types.str; description = "Address the bridge binds (the host's VLAN10 address)."; };
      port = lib.mkOption { type = lib.types.port; default = 8791; };
      allowFrom = lib.mkOption { type = lib.types.str; description = "The only source address let through the firewall (Home Assistant)."; };
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

    # Installs OpenCode (pinned) in the container and its files in the
    # bind-mounted home. The tmux WINDOWS — the server and one terminal per
    # session — belong to the hub below.
    systemd.services.console-qwen-session = lib.mkIf cfg.qwenSession {
      description = "Install OpenCode and the observer's files in the console container";
      after = [ "docker-console.service" ];
      partOf = [ "docker-console.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "10min"; };
      script = let docker = "${config.virtualisation.docker.package}/bin/docker"; in ''
        for _ in $(seq 1 60); do ${docker} exec -u ludorl82 console true 2>/dev/null && break; sleep 2; done
        want=${opencodeVersion}
        have=$(${docker} exec -u ludorl82 console sh -c '$HOME/.local/bin/opencode --version 2>/dev/null' || true)
        if [ "$have" != "$want" ]; then
          echo "installing opencode $want (had: ''${have:-none})"
          ${docker} exec -u ludorl82 console sh -c "npm install -g --prefix \$HOME/.local opencode-ai@$want >/dev/null"
        fi
        d=/home/ludorl82/.local/share/qwen-voice
        # The directory itself first: `install -D` creates missing parents as
        # ROOT (-o only applies to the file), and labo-backlog clones INTO it —
        # a root-owned $d left the observer unable to write its backlog
        # (« clone impossible », 2026-09-27). -d also fixes an existing one.
        ${pkgs.coreutils}/bin/install -d -m 0700 -o ludorl82 -g users $d
        ${pkgs.coreutils}/bin/install -D -m 0600 -o ludorl82 -g users ${opencodeConfig} $d/opencode.json
        ${pkgs.coreutils}/bin/install -D -m 0600 -o ludorl82 -g users ${observerPrompt} $d/observateur.md
        ${pkgs.coreutils}/bin/install -D -m 0700 -o ludorl82 -g users ${opencodeServe} $d/opencode-serve.sh
        ${pkgs.coreutils}/bin/install -D -m 0700 -o ludorl82 -g users ${opencodeAttach} $d/opencode-attach.sh
        # Qwen Code leftovers from before 2026-09-27.
        rm -f $d/qwen-session.sh $d/system-settings.json
        ${pkgs.coreutils}/bin/install -D -m 0600 -o ludorl82 -g users ${qwenInteractiveSettings} $d/qwen-settings.json
        ${pkgs.coreutils}/bin/install -D -m 0700 -o ludorl82 -g users ${qwenInteractive} $d/qwen-interactive.sh
        # The night-jobs Qwen Code session: created if absent, never replaced
        # (it may hold live work).
        tm() { ${docker} exec -u ludorl82 console tmux -L console "$@"; }
        if ! tm has-session -t qwen 2>/dev/null; then
          tm new-session -d -s qwen -n qwen -c /home/ludorl82 "bash --norc --noprofile $d/qwen-interactive.sh" \
            && echo "started the qwen (night jobs) session"
        fi
        # Fast read-only answers for the questions asked most (by voice too):
        # one command instead of ten guesses. On the console's PATH, so Claude,
        # Qwen and a human all use the same ones.
        ${pkgs.coreutils}/bin/install -D -m 0755 -o ludorl82 -g users \
          ${../scripts/labo-alertes.py} /home/ludorl82/.local/bin/labo-alertes
        ${pkgs.coreutils}/bin/install -D -m 0755 -o ludorl82 -g users \
          ${../scripts/labo-sante.sh} /home/ludorl82/.local/bin/labo-sante
        # Qwen's two other doors: hosts read through an allowlist, and the
        # backlog — its only write.
        ${pkgs.coreutils}/bin/install -D -m 0755 -o ludorl82 -g users \
          ${../scripts/labo-lire.sh} /home/ludorl82/.local/bin/labo-lire
        ${pkgs.coreutils}/bin/install -D -m 0755 -o ludorl82 -g users \
          ${../scripts/labo-backlog.sh} /home/ludorl82/.local/bin/labo-backlog
      '';
    };

    # The hub (scripts/qwen-voice-bridge.py): the Qwen sessions' windows, the
    # office voice (HA sees an Ollama server) routed to the ACTIVE session, and
    # tool approvals surfaced to — and answerable from — the Home Assistant app
    # (/qwen/state, /qwen/session, /qwen/approve). The voice never approves.
    # The token rides in "Authorization: Bearer" (the Ollama integration's
    # « API key » field, and a rest_command header). Out-of-band seed, like
    # /var/lib/console/env:
    #   /var/lib/qwen-voice/env   QWEN_VOICE_TOKEN=<token>   (root, 0600)
    # Plus the firewall: the port is open to Home Assistant only.
    # partOf the container: restarting it kills every window, and the hub's
    # startup is what brings them back from the manifest.
    systemd.services.qwen-voice-bridge = lib.mkIf (cfg.qwenSession && cfg.qwenVoiceBridge.enable) {
      description = "Observer hub: OpenCode sessions, office voice and app approvals";
      after = [ "network-online.target" "docker-console.service" "console-qwen-session.service" ];
      wants = [ "network-online.target" ];
      partOf = [ "docker-console.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.virtualisation.docker.package pkgs.bash ];
      environment = {
        QWEN_VOICE_LISTEN = cfg.qwenVoiceBridge.listen;
        QWEN_VOICE_PORT = toString cfg.qwenVoiceBridge.port;
        QWEN_VOICE_STATE = "/home/ludorl82/.local/state/qwen-voice";
        # Session names in gpu-01's vocabulary, like the Claude windows.
        QWEN_NAMEGEN = "${../scripts/claude-window-name.sh}";
      };
      serviceConfig = {
        # ludorl82 is in the docker group: the hub drives tmux in the container.
        User = "ludorl82";
        EnvironmentFile = "/var/lib/qwen-voice/env";
        ExecStart = "${pkgs.python3}/bin/python3 ${../scripts/qwen-voice-bridge.py}";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
    networking.firewall.extraCommands = lib.mkIf (cfg.qwenSession && cfg.qwenVoiceBridge.enable) ''
      iptables -A nixos-fw -p tcp -s ${cfg.qwenVoiceBridge.allowFrom} --dport ${toString cfg.qwenVoiceBridge.port} -j nixos-fw-accept
    '';

    systemd.tmpfiles.rules = [
      "d /home/ludorl82/.ssh 0700 ludorl82 users -"
    ] ++ lib.optionals cfg.qwenSession [
      "d /home/ludorl82/.local/state/qwen-voice 0700 ludorl82 users -"
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
