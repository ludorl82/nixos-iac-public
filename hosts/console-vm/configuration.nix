## console-vm: the console VM on gpu-01 — the interactive admin workspace,
## reborn as a dedicated VM in the 2026-08-07 jumphost/console split (the
## name previously meant the Pi-4 jumphost, then a DNS alias to pi-02).
## Same libvirt/macvtap shape as vm-01-on-gpu-01: guest sits directly on
## VLAN10 (untagged to the guest), static IP matched by the VM's fixed MAC.
##
## Deliberately NOT a k3s agent — the console manages the cluster, it
## doesn't join it. Its home directory is seeded from the nightly S3
## tarball + git clones (scripts/seed-console-home.sh); the machine itself
## is disposable.
##
## Out-of-band seeds at install time (nixos-anywhere --extra-files):
##   /etc/comin/github-token   — comin GitOps enrollment
##   /var/lib/console/env      — PASS=<console user password>
##   /var/lib/console/ssh/     — the container's stable sshd host keys
{ pkgs, lib, ... }:

let
  # Home Assistant's Claude-window buttons. Same shape as gaming-01's arcade-ctl
  # and pi-02's power-ctl: reads $SSH_ORIGINAL_COMMAND, does one thing, and
  # can do nothing else.
  #
  # Every tmux call goes through `-L console` — the named socket that
  # console-claude-session creates at boot and the interactive console
  # (tmuxinator) attaches to; the image itself starts no tmux at all.
  # Plain `tmux` silently opens a SECOND server, and the windows would exist
  # where nobody can see them (see modules/console-container.nix).
  claudeWindowName = pkgs.writeShellScript "claude-window-name"
    (builtins.readFile ../../scripts/claude-window-name.sh);

  claudeCtl = pkgs.writeShellScript "claude-ctl" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:/run/current-system/sw/bin:$PATH
    set -- $SSH_ORIGINAL_COMMAND
    action="$1"
    target="$2"

    tm() { docker exec -u ludorl82 console tmux -L console "$@"; }

    # No session means the boot unit has not run (or failed), or the
    # container was restarted underneath it. For `add` — the button a human
    # presses to get a Claude window — bring the session up the same way a
    # boot does: (re)start console-claude-session, which creates the tmux
    # server on the named socket and replays the window snapshot. `restart`,
    # not `start`: the oneshot is RemainAfterExit, so after a container
    # restart it still reads "active" and `start` would be a no-op. Every
    # other verb keeps refusing — the minute-by-minute HA sensor must not
    # resurrect sessions somebody stopped on purpose.
    if ! tm has-session -t claude 2>/dev/null; then
      if [ "$action" = add ]; then
        /run/wrappers/bin/sudo -n systemctl restart console-claude-session.service >/dev/null 2>&1 || true
        if tm has-session -t claude 2>/dev/null; then
          echo "started the 'claude' session: $(tm list-windows -t claude -F '#{window_name}' | tr '\n' ' ')"
          exit 0
        fi
        echo "no 'claude' tmux session and console-claude-session could not start it"; exit 1
      fi
      echo "no 'claude' tmux session; is console-claude-session up?"; exit 1
    fi

    case "$action" in
      add)
        # Name the window and its Remote Control session after the next free
        # index, so the two correlate in the phone's session list.
        last="$(tm list-windows -t claude -F '#{window_index}' | sort -n | tail -1)"
        n="$((last + 1))"
        # `-t claude:$n` — the colon makes the target a SESSION at an explicit
        # index. Bare `-t claude` is a WINDOW spec and resolves to the session's
        # current window, so tmux answers "index N in use" and creates nothing.
        # The explicit index also keeps window number, window name and Remote
        # Control session suffix identical, which is what makes them findable.
        # Fix the session id at launch rather than discovering it later: a
        # running Claude holds no open handle on its transcript, so there is no
        # way to read it back off the process. Assigning it is what makes the
        # window restorable after a cold boot.
        uuid="$(cat /proc/sys/kernel/random/uuid)"
        # A phrase, not claude-$n. The same string names the window AND its
        # Remote Control session, so a numbered scheme gives the phone a list
        # of near-identical entries; COBALT-OTTER-89 is recognisable at a
        # glance. Existing names are passed in so it never reuses one.
        taken="$(tm list-windows -t claude -F '#{window_name}' | tr '\n' ' ')"
        wname="$(${claudeWindowName} $taken)"
        if ! tm new-window -t "claude:$n" -n "$wname" -c /home/ludorl82/tmp \
             "/home/ludorl82/.local/bin/claude --session-id $uuid --remote-control $wname"; then
          echo "failed to create window $wname"; exit 1
        fi
        # The window carries its own id, so the snapshot is a pure read of live
        # tmux state and cannot drift from it.
        tm set-option -w -t "claude:$n" @claude_session_id "$uuid"
        echo "added window $wname"
        ;;
      remove)
        # Refuse on the last one: killing the final window ends the session,
        # and the session is the boot unit's deliverable, not a window.
        count="$(tm list-windows -t claude | wc -l)"
        if [ "$count" -le 1 ]; then
          echo "refusing: 'claude' has one window left; that is the session"
          exit 1
        fi
        if [ -n "$target" ]; then
          # Named removal, from HA's dropdown. The dropdown can hold a name for
          # up to its refresh interval after the window is gone, so an unknown
          # name must be REFUSED rather than resolved to something else — index
          # positions shift when a window dies, and a fallback would kill an
          # innocent window that happens to sit where the dead one was.
          if ! tm list-windows -t claude -F '#{window_name}' | grep -qxF "$target"; then
            echo "denied: no such window '$target'"; exit 1
          fi
          tm kill-window -t "claude:$target"
          echo "removed window $target"
        else
          # No argument: the original stack behaviour, still used as the
          # fallback when the dropdown is empty.
          last="$(tm list-windows -t claude -F '#{window_index}' | sort -n | tail -1)"
          gone="$(tm list-windows -t claude -F '#{window_index} #{window_name}' | awk -v i="$last" '$1 == i {print $2}')"
          tm kill-window -t "claude:$last"
          echo "removed window ''${gone:-$last}"
        fi
        ;;
      count) tm list-windows -t claude | wc -l ;;
      list)  tm list-windows -t claude -F '#{window_index} #{window_name}' ;;
      names)
        # Machine-readable twin of `list`, for HA's command_line sensor:
        # {"count": N, "windows": ["a","b"]}. Assembled by hand rather than with
        # jq — the console image is not guaranteed to carry it, and the values
        # are our own [a-z0-9-] window names, so there is nothing to escape.
        names="$(tm list-windows -t claude -F '#{window_name}')"
        n=0; list=""
        for w in $names; do
          n="$((n + 1))"
          if [ -z "$list" ]; then list="\"$w\""; else list="$list, \"$w\""; fi
        done
        echo "{\"count\": $n, \"windows\": [$list]}"
        ;;
      rename)
        # Rename a window AND its Claude session in one shot, from HA. $2 is the
        # dropdown pick (old name); everything after is the free-form new name.
        old="$2"
        new=""
        if [ "$#" -ge 3 ]; then shift 2; new="$*"; fi
        if [ -z "$old" ] || [ -z "$new" ]; then echo "denied: rename needs <old> <new>"; exit 1; fi
        # Slugify: lowercase, every non-alnum run -> '-', squeeze, trim. HA already
        # slugifies before the shell, but doing it here too makes the verb safe when
        # called directly and neutralises any tmux/send-keys metacharacter.
        slug="$(printf '%s' "$new" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')"
        slug="''${slug#-}"; slug="''${slug%-}"
        if [ -z "$slug" ]; then echo "denied: name has no usable characters"; exit 1; fi
        # Unknown old name is REFUSED, never resolved to a neighbour (indices
        # shift) — same reasoning as remove.
        if ! tm list-windows -t claude -F '#{window_name}' | grep -qxF "$old"; then
          echo "denied: no such window '$old'"; exit 1
        fi
        if tm list-windows -t claude -F '#{window_name}' | grep -qxF "$slug"; then
          echo "denied: name '$slug' already in use"; exit 1
        fi
        tm rename-window -t "claude:$old" "$slug"
        # Rename the Claude session too (updates the Remote Control label). C-u
        # wipes any half-typed input first; $slug is [a-z0-9-] so the payload is
        # safe. The window's Claude is the active pane, so no pane index.
        tm send-keys -t "claude:$slug" C-u "/rename $slug" Enter
        echo "renamed $old -> $slug"
        ;;
      *) echo "denied: bad action"; exit 1 ;;
    esac
  '';
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/private-ca.nix
    ../../modules/jumphost-tools.nix
    ../../modules/console-container.nix
  ];

  # The real console: autoStart (the default) with room to work — the whole
  # point of the move off the 4 GiB Pi. VM gets 16 GiB; the container cap
  # leaves headroom for the host and nested docker builds.
  homelab.console.memoryLimit = "12g";
  homelab.console.memorySwap = "16g";
  # amd64 build of 2026-08-07 (gpu-01, console-entry.sh shim included) — the
  # x86_64 counterpart of pi-02's arm64 pin. Registry tag :arm64 preserves
  # the old manifest from GC; a true multi-arch index replaces both pins
  # when pi-02's container next updates (Phase 4/5).
  homelab.console.image = "docker.lab.example:5000/console-personal@sha256:5f420318906472e1f9804e21ef8ce8eaf03c9191a8edbd4d656a3d05b8f15dad";
  # /var/lib/console/ssh was seeded at install (pi-02's container key) —
  # the :2222 identity is therefore the SAME as today's console.
  homelab.console.stableHostKeys = true;
  # Remote Control on boot, so the phone can reach this console without an
  # SSH-in first. Only here — pi-02's emergency console stays silent.
  homelab.console.claudeSession = true;

  networking.hostName = "console-vm";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      # IPv6 follows the hex(last-octet) convention (136 -> 0x88). Reachable
      # inbound only because this VM's macvtap <interface> carries
      # trustGuestRxFilters='yes' AND model virtio - see
      # hosts/console-vm/libvirt-domain.xml.
      Address = [
        "192.0.2.136/23"
        "2001:db8:50:a::88/64"
      ];
      Gateway = "192.0.2.254";
      DNS = "192.0.2.254";
      IPv6AcceptRA = true;
    };
    # NB: no RequiredForOnline=no here - it's the primary NIC, and setting
    # that makes systemd-networkd-wait-online fail (vm-02 lesson). Also add
    # the "~." domain so systemd-resolved routes all lookups at pfSense
    # (vm-02 lesson - otherwise internal names fall to public fallback DNS).
    domains = [ "lab.example" "example.com" "~." ];
  };
  # Untagged VLAN50, via a SECOND macvtap interface on gpu-01's `eno2` (VLAN50
  # is the untagged/native VLAN on that trunk; `vlan10` is the tagged
  # sub-interface the primary NIC rides on). Secondary: address only,
  # deliberately no gateway, so the default route stays exclusively on
  # VLAN10. RequiredForOnline=no is correct HERE - it is wrong on 10-lan
  # above, which is the link wait-online must actually wait for.
  systemd.network.networks."20-vlan50" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig.Address = "203.0.113.136/23";
    linkConfig.RequiredForOnline = "no";
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.ludorl82 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      # Home Assistant's Claude-window buttons — forced to claudeCtl, nothing
      # else. This list is ALSO rendered into the container's
      # ~/.ssh/authorized_keys, where that store path does not exist, so the
      # key fails closed on :2222 and works only against the host sshd — which
      # is the one in the docker group, and the one HA dials.
      ''command="${claudeCtl}",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      # The one Cronicle job that follows the console: Weekly IaC update PRs
      # hits the CONTAINER on :2222, but the key lands in the container's
      # ~/.ssh/authorized_keys via console-container.nix's render of this
      # host list.
      ''command="/home/ludorl82/scripts/weekly-iac-updates.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      # Nightly console-home backup (the console-vm/ S3 prefix resumes on this
      # VM). Dedicated keypair per (script, host) policy — Secret
      # cronicle-ssh-backup-console-vm, event "Homelab Backup (console-vm VM)".
      ''command="/home/ludorl82/scripts/homelab-backup.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      # Nightly diagram sync (network-diagram.md reconcile + blog shape
      # diagram) — Secret cronicle-ssh-diagram-sync, event "Nightly Diagram
      # Sync". Runtime copy in ~/scripts like its siblings.
      ''command="/home/ludorl82/scripts/nightly-diagram-sync.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example fleet-deploy"
      # The morning chain (2026-08-09): Cronicle became the only scheduler for
      # the diagram pipeline, so the three jobs that drive it dial the
      # container on :2222 like their siblings above. One dedicated keypair
      # per script, per policy — Secrets cronicle-ssh-{drift-dispatch,
      # arch-refresh,snapshot-publish}.
      #
      # Declared here rather than appended on the box: this module's activation
      # script rewrites the container's ~/.ssh/authorized_keys from THIS list
      # on every switch. Appending by hand works right up until the next comin
      # deploy silently drops it — which is exactly what happened while wiring
      # these up (12:11, mid-verification, two jobs that had just passed).
      ''command="/home/ludorl82/scripts/dispatch-drift-checks.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      ''command="/home/ludorl82/scripts/arch-refresh.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      # No timing on this one's event: publishing the sanitized snapshots is
      # the step that crosses private -> public, and stays a human decision.
      ''command="/home/ludorl82/scripts/publish-snapshots.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  system.stateVersion = "26.05";
}
