# labo.kiosk — the rack screen's kiosk: every machine's console on a numpad.
#
# WHY (2026-10-09). Ludo wants the rack screen to show the consoles of the
# fleet — the BMCs' iKVM, later One-KVM pages for vega and the work
# laptop — one per numpad key, screen off after ten idle minutes. Backlog:
# net-cfgs/backlog.md, "Kiosques du rack".
#
# ONE KIOSK, ON ITS OWN OUTPUT AND ITS OWN SEAT. The first version (same day)
# ran a kiosk on bob AND stella on their onboard ASPEED VGA — the very output
# the BMC's iKVM captures. So bob's iKVM showed bob's kiosk instead of bob's
# console, and stella's desktop showed stella showing itself. Now:
#   - the ASPEED (VGA, iKVM, the VGA switch) keeps the host's text console;
#   - the kiosk runs on the host's own graphics card (stella: the RTX 3050's
#     HDMI, into the BenQ's HDMI input), as systemd-logind seat1: the card,
#     the numpad and the rack's USB keyboard/mouse belong to seat1, the BMC's
#     VGA and the virtual terminals stay seat0. Both show at once.
#   - `driver` says which kernel driver that card has: "nvidia" (stella), or
#     "radeon" (kiosque, 2026-10-14: an X9SCM-F with a Radeon HD "Cedar",
#     TeraScale 2, too old for amdgpu). Only the NVIDIA one needs GBM and GLX
#     overrides, sway's --unsupported-gpu, and kiosk-screen's module reload.
#   - every machine, stella included, is reached from the rack through its
#     iKVM desktop. bob has no kiosk any more.
#
# THE BMC's OWN KEYBOARD STAYS ON SEAT0. The iKVM types through a virtual USB
# keyboard/mouse the BMC presents to its host (ATEN, vendor 0557 — "HID
# 0557:2419" on stella). It must keep reaching the console, so it is the one
# USB input device NOT moved to seat1.
#
# STRAY KEYS AND TTY1. The kernel hands every keyboard to the ACTIVE virtual
# terminal, whatever its seat: what is typed into the kiosk (passwords of
# other machines included) would also land in a login prompt on tty1. So tty1
# holds no prompt: it shows the journal, read-only, echo off. The login is on
# tty2 — Ctrl+Alt+F2 from the iKVM, Ctrl+Alt+F1 back.
#
# THE NUMPAD IS MATCHED BY DEVICE AND BY KEYCODE. `bindcode --input-device`
# makes only that pad switch desktops: the digits of a real keyboard stay
# digits. Keycodes, not keysyms, because the pad toggles NumLock by itself
# around every burst of keys (evtest on stella, 2026-10-09: NUMLOCK, KP1,
# KP2, KP3, KPENTER, NUMLOCK).
#
# THE BMC SESSIONS ARE SCARCE. A desktop logs in only when used (a key, or
# the screen waking up), logs out when the screen sleeps, and the service
# logs everything out before it stops: a Chromium killed outright left its
# sessions open on the BMCs until they expired, and the next viewer got
# "Server disconnected (code 1006)" (2026-10-09). kiosk-bmc
# (scripts/kiosk-bmc.py) logs in through the BMC's own form — the X11 menu
# hides the HTML5 iKVM, but its direct URL works — and a watcher per desktop
# dismisses the BMC's alerts and reconnects.
#
# SECRETS: the BMC passwords are seeded by hand, never in git, as for
# modules/rack-wake.nix: /var/lib/kiosk/bmc-<host>, root:kiosk 0640. A missing
# file leaves that desktop on its placeholder, it does not break the kiosk.
#
# A DEPLOY DOES NOT RESTART THE SCREEN (restartIfChanged = false): a new
# config takes effect at `systemctl restart kiosk` or the next boot.
{ config, lib, pkgs, ... }:
let
  cfg = config.labo.kiosk;

  # The BMCs a desktop can show. Names resolve through pfSense; the cert
  # (*.ipmi.lab.example, private CA) covers them.
  bmcs = {
    bob = "https://bob.ipmi.lab.example";
    luna = "https://luna.ipmi.lab.example";
    stella = "https://stella.ipmi.lab.example";
  };

  # Each desktop's numpad key: its own `key`, or its rank in the list.
  keyed = lib.imap1 (i: d: d // { key = if d.key != null then d.key else i; }) cfg.desktops;
  keys = map (d: d.key) keyed;

  # A capture desktop: a USB HDMI capture card served by ustreamer on
  # 127.0.0.1 only (port 8100 + key, modules/kiosk-capture.nix), shown by a
  # page that fills the screen with its MJPEG stream and retries while there
  # is no signal. A card plugged into another host (`host`, 2026-10-14: the
  # work laptop's two screens stay on stella) is served there, on the same
  # port, and reached through an SSH tunnel to that host's 127.0.0.1: the page
  # cannot tell the difference.
  capturePort = d: 8100 + d.key;
  captures = lib.filter (d: d.kind == "capture") keyed;
  localCaptures = lib.filter (d: d.host == null) captures;
  remoteCaptures = lib.filter (d: d.host != null) captures;
  captureHosts = lib.unique (map (d: d.host) remoteCaptures);
  tunnelKey = "/var/lib/kiosk/tunnel/id_ed25519";
  captureViewer = pkgs.writeTextDir "share/kiosk/capture.html" ''
    <!doctype html><meta charset="utf-8"><title>capture</title>
    <body style="margin:0;background:#000;overflow:hidden">
    <img id="v" style="width:100vw;height:100vh;object-fit:contain">
    <script>
      var v = document.getElementById("v"), port = location.hash.slice(1);
      function load() { v.src = "http://127.0.0.1:" + port + "/stream?t=" + Date.now(); }
      v.onerror = function () { setTimeout(load, 3000); };
      load();
    </script>
  '';
  desktopUrl = d:
    if d.kind == "bmc" then bmcs.${d.name}
    else if d.kind == "capture" then "file://${captureViewer}/share/kiosk/capture.html#${toString (capturePort d)}"
    else if d.kind == "console" then "-"
    else d.url;

  desktopsFile = pkgs.writeText "kiosk-desktops" (lib.concatMapStrings (d:
    "${toString d.key} ${d.kind} ${d.name} ${desktopUrl d}\n")
    keyed);

  # One kiosk: no peer to keep in step with (kiosk-desktop skips the push).
  peerFile = pkgs.writeText "kiosk-peer" "";

  placeholder = pkgs.writeTextDir "share/kiosk/index.html" ''
    <!doctype html><meta charset="utf-8"><title>kiosque</title>
    <body style="margin:0;background:#000;color:#9a9a9a;font:28px sans-serif;
      display:flex;align-items:center;justify-content:center;height:100vh">
    <div id="m"></div>
    <script>
      var h = decodeURIComponent(location.hash.slice(1)).split("-");
      document.getElementById("m").textContent =
        "Bureau " + h[0] + " — " + (h[1] || "") + " : appuie sur une touche du pavé pour te connecter";
    </script>
  '';
  placeholderUrl = "file://${placeholder}/share/kiosk/index.html";

  kioskBmc = pkgs.writeScriptBin "kiosk-bmc" (
    "#!${pkgs.python3.withPackages (ps: [ ps.websocket-client ])}/bin/python3\n"
    + builtins.readFile ../scripts/kiosk-bmc.py);

  # The rack keyboard, taken from stella's console and replayed into the
  # compositor: see scripts/kiosk-keys.c.
  kioskKeysBin = pkgs.stdenv.mkDerivation {
    name = "kiosk-keys";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.wayland-scanner pkgs.pkg-config ];
    buildInputs = [ pkgs.wayland pkgs.libxkbcommon ];
    buildPhase = let proto = "${pkgs.wlroots_0_19.src}/protocol/virtual-keyboard-unstable-v1.xml"; in ''
      wayland-scanner client-header ${proto} virtual-keyboard-unstable-v1-client-protocol.h
      wayland-scanner private-code ${proto} virtual-keyboard-unstable-v1-protocol.c
      $CC -O2 -Wall -Wextra -Werror -I. -o kiosk-keys ${../scripts/kiosk-keys.c} \
        virtual-keyboard-unstable-v1-protocol.c $(pkg-config --cflags --libs wayland-client xkbcommon)
    '';
    installPhase = "install -Dm755 kiosk-keys $out/bin/kiosk-keys";
  };
  # Again after an exit (compositor restarted) or a crash: while it is not
  # running, the rack keyboard reaches stella's console directly.
  kioskKeys = pkgs.writeShellScriptBin "kiosk-keys-loop" ''
    while :; do
      ${kioskKeysBin}/bin/kiosk-keys '/dev/input/kiosk-key-*' \
        ${lib.escapeShellArg (toString cfg.numpadDevice)} ${lib.escapeShellArg xkbOptions} || true
      sleep 2
    done
  '';

  # A console desktop: this host's own console, as a terminal on the kiosk.
  # The kiosk machine's console is on the BMC's VGA, and the X9SCM's iKVM is
  # Java only: the kiosk cannot show it (2026-10-14). So the terminal asks
  # for consoleUser's password (su -l) and gives that user a shell; when it
  # ends, it asks again. The kiosk user's own shell is never reachable: the
  # loop runs su and nothing else, and a Ctrl+C between two prompts is caught
  # (a handler, not an ignore: an ignored signal would stay ignored in the
  # user's shell). kiosk-desktop closes the terminal when the screen sleeps,
  # as it logs out of the BMCs: no shell stays open on an unattended screen.
  consoleLogin = pkgs.writeShellScript "kiosk-console-login" ''
    trap : INT QUIT TSTP
    while :; do
      printf '\033[2J\033[H%s — console (%s)\n\n' ${lib.escapeShellArg config.networking.hostName} ${lib.escapeShellArg cfg.consoleUser}
      /run/wrappers/bin/su -l ${lib.escapeShellArg cfg.consoleUser} || true
      sleep 1
    done
  '';
  kioskConsole = pkgs.writeShellScriptBin "kiosk-console" ''
    # kiosk-console N: desktop N's terminal, app-id kiosk<N>-console so that
    # kiosk-wf place finds it like a Chromium.
    exec ${pkgs.foot}/bin/foot --app-id="kiosk$1-console" \
      --override=font=monospace:size=13 -- ${consoleLogin}
  '';

  kioskWf = pkgs.writeScriptBin "kiosk-wf" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../scripts/kiosk-wf.py);

  kioskDesktop = pkgs.writeShellApplication {
    name = "kiosk-desktop";
    runtimeInputs = with pkgs; [ coreutils gnugrep gawk procps openssh sway wlopm chromium kioskBmc kioskWf kioskConsole ];
    text = builtins.readFile ../scripts/kiosk-desktop.sh;
    runtimeEnv = {
      KIOSK_DESKTOPS = "${desktopsFile}";
      KIOSK_PEER = "${peerFile}";
      KIOSK_KEY = "/var/lib/kiosk/sync/id_ed25519";
      KIOSK_PWDIR = "/var/lib/kiosk";
      KIOSK_PROFILES = "/var/lib/kiosk/chromium";
      KIOSK_PLACEHOLDER = placeholderUrl;
    };
  };

  # evdev keycode + 8 = xkb keycode, what bindcode takes.
  kp = { "1" = 87; "2" = 88; "3" = 89; "4" = 83; "5" = 84; "6" = 85; "7" = 79; "8" = 80; "9" = 81;
         "0" = 90; minus = 82; plus = 86; };

  numpadBinds = lib.concatMapStrings (dev: ''
    ${lib.concatMapStrings (d:
      "bindcode --input-device=${dev} ${toString kp.${toString d.key}} exec kiosk-desktop goto ${toString d.key}\n")
      keyed}
    bindcode --input-device=${dev} ${toString kp."0"} exec kiosk-desktop reload
    bindcode --input-device=${dev} ${toString kp.minus} exec kiosk-desktop prev
    bindcode --input-device=${dev} ${toString kp.plus} exec kiosk-desktop next
  '') cfg.numpad;

  # The host's xkb options (Caps Lock = Ctrl, modules/caps-ctrl.nix) on the
  # kiosk too: what is typed into an iKVM behaves like the console itself.
  xkbOptions = config.services.xserver.xkb.options;

  swayConfig = pkgs.writeText "kiosk-sway.conf" ''
    output * bg #000000 solid_color
    default_border none
    default_floating_border none
    focus_follows_mouse no
    seat * hide_cursor 3000
    input type:keyboard xkb_numlock enabled
    ${lib.optionalString (xkbOptions != "") "input type:keyboard xkb_options ${xkbOptions}"}
    for_window [app_id=".*"] fullscreen enable
    ${numpadBinds}
    exec kiosk-keys-loop
    exec kiosk-idle
    exec kiosk-desktop start
  '';

  # --- Wayfire, for the cube -------------------------------------------
  # One face per desktop, in key order (kiosk-desktop's index()). The cube
  # turns by IPC (kiosk-wf rotate); the numpad is read by evsieve, Wayfire
  # having no per-device bindings. No `idle` plugin: with a full-screen window
  # it inhibits idle, and swayidle would never fire.
  wayfireConfig = pkgs.writeText "kiosk-wayfire.ini" ''
    [core]
    plugins = ipc ipc-rules vswitch cube wm-actions window-rules autostart
    vwidth = ${toString (lib.max 2 (lib.length cfg.desktops))}
    vheight = 1
    background_color = \#000000FF

    [cube]
    initial_animation = 400ms
    background = \#000000FF
    zoom = 0.0
    activate = none
    rotate_left = none
    rotate_right = none

    [vswitch]
    duration = 300ms

    [input]
    xkb_options = ${xkbOptions}

    [workarounds]
    force_frame_sync = true

    [autostart]
    autostart_wf_shell = false
    numpad = kiosk-numpad
    keys = kiosk-keys-loop
    idle = kiosk-idle
    desktops = kiosk-desktop start
  '';

  # swayidle in a loop: the numpad's commands kill it to restart the ten
  # minutes (kiosk-desktop wake), and a fresh one takes over.
  kioskIdle = pkgs.writeShellScriptBin "kiosk-idle" ''
    while :; do
      swayidle -w timeout ${toString cfg.idleSeconds} 'kiosk-desktop sleep; wlopm --off "*"' \
        resume 'wlopm --on "*"; kiosk-desktop resume'
      sleep 1
    done
  '';

  # The numpad under Wayfire: evsieve takes the pad alone (grab) and runs a
  # command per key. It needs the device present to start, and the USB switch
  # takes it away and back: wait for it, run, wait again.
  kioskNumpad = pkgs.writeShellScriptBin "kiosk-numpad" ''
    dev=${lib.escapeShellArg (toString cfg.numpadDevice)}
    while :; do
      while [ ! -e "$dev" ]; do sleep 2; done
      ${pkgs.evsieve}/bin/evsieve --input "$dev" grab persist=reopen \
        ${lib.concatMapStrings (d:
          "--hook key:kp${toString d.key} exec-shell=\"kiosk-desktop goto ${toString d.key}\" \\\n        ")
          keyed}--hook key:kp0 exec-shell="kiosk-desktop reload" \
        --hook key:kpminus exec-shell="kiosk-desktop prev" \
        --hook key:kpplus exec-shell="kiosk-desktop next" || true
      sleep 2
    done
  '';

  nvidia = cfg.driver == "nvidia";

  session = pkgs.writeShellScript "kiosk-session" ''
    set -u
    # The kiosk card's display node only (the BMC's VGA is seat0's), GLES:
    # the cube needs it.
    export WLR_DRM_DEVICES=/dev/dri/kiosk-card WLR_RENDERER=gles2
    ${lib.optionalString nvidia ''
    # NVIDIA renders through its own GBM backend, sway wants --unsupported-gpu
    # for the proprietary driver, and hardware cursors misbehave on it.
    export WLR_NO_HARDWARE_CURSORS=1
    export GBM_BACKEND=nvidia-drm __GLX_VENDOR_LIBRARY_NAME=nvidia
    ''}
    export XDG_SESSION_TYPE=wayland
    # sway runs every `exec` through `sh -c`, looking `sh` up in PATH: without
    # bash here, swayidle and the desktops silently never start (stella,
    # 2026-10-09, first start).
    export PATH=${lib.makeBinPath [ kioskDesktop kioskBmc kioskWf kioskNumpad kioskKeys kioskIdle pkgs.sway pkgs.swayidle pkgs.wlopm pkgs.chromium pkgs.coreutils pkgs.bash ]}
    # Trust the private CA in the kiosk's own NSS store: Chromium reads that,
    # not /etc/ssl. No --ignore-certificate-errors.
    db="sql:$HOME/.pki/nssdb"
    mkdir -p "$HOME/.pki/nssdb"
    ${pkgs.nss.tools}/bin/certutil -d "$db" -L >/dev/null 2>&1 \
      || ${pkgs.nss.tools}/bin/certutil -d "$db" -N --empty-password
    ${pkgs.nss.tools}/bin/certutil -d "$db" -A -t "C,," -n labo-private-ca -i ${./pki.example.com.crt}

    # WAYFIRE FIRST, SWAY IF IT KEEPS DYING. Wayfire's cube on the proprietary
    # NVIDIA driver is unproven (an open bug crashes it when a buffer
    # allocation fails, and the cube allocates one per face), and on a 2010
    # Radeon untried. Two deaths in under a minute each and the kiosk runs
    # sway instead, until a Wayfire session has lasted ten minutes again —
    # or the counter is removed.
    fails=/var/lib/kiosk/wayfire-failures
    if [ ${lib.boolToString (cfg.compositor == "wayfire")} = true ] && [ "$(cat "$fails" 2>/dev/null || echo 0)" -lt 2 ]; then
      export KIOSK_WM=wayfire
      start=$(date +%s)
      ${pkgs.wayfire}/bin/wayfire -c ${wayfireConfig}
      ran=$(( $(date +%s) - start ))
      if [ "$ran" -lt 60 ]; then
        echo $(( $(cat "$fails" 2>/dev/null || echo 0) + 1 )) > "$fails"
        echo "kiosk: wayfire ended after ''${ran}s ($(cat "$fails") quick end(s))" >&2
      elif [ "$ran" -ge 600 ]; then
        echo 0 > "$fails"
      fi
      exit 0   # Restart=always brings the session back
    fi
    export KIOSK_WM=sway
    exec ${pkgs.sway}/bin/sway ${lib.optionalString nvidia "--unsupported-gpu "}--config ${swayConfig}
  '';

  # Before the session: is a screen plugged into the kiosk card? After a
  # reboot (the weekly update, 2026-10-11), the 3050 saw no screen on its
  # HDMI and never looked again: Wayfire drew on a dummy output for a day.
  # Unplugging the cable and a forced detect changed nothing; reloading the
  # NVIDIA modules did (2026-10-12). So: ask again, then reload. Nothing else
  # uses the card's display side, and the kiosk is stopped at this point; if
  # k3s holds the compute side (nvidia, nvidia_uvm), modprobe -r stops there
  # and nvidia_drm comes back anyway. Only NVIDIA has shown this; on another
  # driver the script asks again and reports, without reloading anything.
  screen = pkgs.writeShellScript "kiosk-screen" ''
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.kmod pkgs.systemd ]}
    connected() {
      for c in /sys/class/drm/card*-*; do
        [ "$(readlink -f "$c/device/device/driver")" = /sys/bus/pci/drivers/${cfg.driver} ] || continue
        [ "$(cat "$c/status")" = connected ] && return 0
      done
      return 1
    }
    connected && exit 0
    for c in /sys/class/drm/card*-*; do { echo detect > "$c/status"; } 2>/dev/null; done
    sleep 3
    connected && exit 0
    ${if nvidia then ''
    echo "kiosk-screen: no screen on the NVIDIA card, reloading its modules"
    modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia || true
    modprobe nvidia_drm; modprobe nvidia_uvm'' else ''
    echo "kiosk-screen: no screen on the ${cfg.driver} card"''}
    udevadm settle --timeout=10 || true
    sleep 2
    connected && echo "kiosk-screen: screen found" || echo "kiosk-screen: still no screen"
    exit 0
  '';

  # Log every desktop out of its BMC while the session still runs.
  logout = pkgs.writeShellScript "kiosk-logout" ''
    uid=$(${pkgs.coreutils}/bin/id -u kiosk) || exit 0
    [ -d "/run/user/$uid/kiosk" ] || exit 0
    XDG_RUNTIME_DIR="/run/user/$uid" ${pkgs.coreutils}/bin/timeout 25 \
      ${kioskDesktop}/bin/kiosk-desktop sleep || true
  '';

  # seat1 = the kiosk card + every USB input device but the BMC's virtual
  # keyboard/mouse (vendor 0557: ATEN on the X11SRA, the Winbond "Hermon" of
  # the X9SCM's WPCM450 carries the same id — read on kiosque, 2026-10-14).
  # Numbered 72 on purpose: ID_SEAT must be set before systemd's
  # 73-seat-late.rules, which defaults it to seat0 and hands out device ACLs
  # (uaccess) by seat.
  seatRules = pkgs.writeTextDir "lib/udev/rules.d/72-kiosk-seat.rules" ''
    SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="${cfg.driver}", TAG+="seat", TAG+="cp-1-of-seat", ENV{ID_SEAT}="seat1", SYMLINK+="dri/kiosk-card"
    SUBSYSTEM!="input", GOTO="kiosk_seat_end"
    ATTRS{idVendor}=="0557", GOTO="kiosk_seat_end"
    ENV{ID_BUS}=="usb", TAG+="seat", ENV{ID_SEAT}="seat1"
    # The seat's keyboards, for kiosk-keys to take from the console.
    ENV{ID_BUS}=="usb", KERNEL=="event*", ENV{ID_INPUT_KEY}=="1", SYMLINK+="input/kiosk-key-%k"
    LABEL="kiosk_seat_end"
  '';
in
{
  imports = [ ./kiosk-capture.nix ];

  options.labo.kiosk = {
    enable = lib.mkEnableOption "the rack kiosk on this host's graphics card, as logind seat1";
    driver = lib.mkOption {
      type = lib.types.enum [ "nvidia" "radeon" ];
      default = "nvidia";
      description = "Kernel driver of the kiosk's card (the one that is not the BMC's VGA).";
    };
    desktops = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          kind = lib.mkOption { type = lib.types.enum [ "bmc" "web" "capture" "console" ]; };
          name = lib.mkOption { type = lib.types.strMatching "[a-z0-9-]+"; };
          url = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          device = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/dev/v4l/by-id/usb-ITE_UGREEN_25173_00000001-video-index0";
            description = "capture: the capture card's V4L2 device (by-id path), when it is plugged into this host.";
          };
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "stella";
            description = "capture: the host the card is plugged into, which serves it (labo.kioskCapture); null = this host.";
          };
          key = lib.mkOption {
            type = lib.types.nullOr (lib.types.ints.between 1 9);
            default = null;
            description = "Numpad key (and sway workspace); null = rank in the list.";
          };
        };
      });
      description = "Desktops; each on its `key` (default: its rank). bmc: name is a host of the BMC table; web: url is shown as is.";
    };
    compositor = lib.mkOption {
      type = lib.types.enum [ "wayfire" "sway" ];
      default = "sway";
      description = "wayfire = the cube, with sway as the automatic fallback; sway = no animation.";
    };
    numpadDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/input/by-id/usb-SINO_WEALTH_Gaming_KB-event-kbd";
      description = "The numpad's event device, read by evsieve under Wayfire.";
    };
    numpad = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "9610:58:SINO_WEALTH_Gaming_KB" ];
      description = "sway input identifiers (swaymsg -t get_inputs) of the numpad(s) that switch desktops.";
    };
    idleSeconds = lib.mkOption { type = lib.types.ints.positive; default = 600; };
    consoleUser = lib.mkOption {
      type = lib.types.str;
      default = "ludorl82";
      description = "console: the user whose password the terminal asks for.";
    };
    captureHostKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { stella = "ssh-ed25519 AAAA..."; };
      description = "SSH host key of each host serving a remote capture card, pinned for the tunnel.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [ {
    assertions = [
      { assertion = lib.length cfg.desktops >= 1 && lib.length cfg.desktops <= 9;
        message = "labo.kiosk: 1 to 9 desktops (one numpad digit each)"; }
      { assertion = lib.length (lib.unique keys) == lib.length keys;
        message = "labo.kiosk: two desktops on the same numpad key"; }
      { assertion = lib.all (d:
          if d.kind == "bmc" then bmcs ? ${d.name}
          else if d.kind == "capture" then (d.device != null) != (d.host != null)
          else if d.kind == "console" then true
          else d.url != null) cfg.desktops;
        message = "labo.kiosk: bmc needs a known BMC, web a url, capture a device or a host (not both)"; }
      { assertion = lib.all (h: cfg.captureHostKeys ? ${h}) captureHosts;
        message = "labo.kiosk: every capture host needs its SSH host key in captureHostKeys"; }
      { assertion = cfg.compositor != "wayfire" || cfg.numpadDevice != null;
        message = "labo.kiosk: under Wayfire the numpad is read by evsieve: set numpadDevice"; }
      { assertion = !nvidia || config.hardware.nvidia.modesetting.enable;
        message = "labo.kiosk: the kiosk draws on the NVIDIA card, which needs hardware.nvidia.modesetting"; }
    ];

    # Mesa (GBM, GLES) for Wayfire and sway. stella had it through its NVIDIA
    # setup; kiosque's Radeon has nothing else asking for it.
    hardware.graphics.enable = true;

    users.groups.kiosk = { };
    users.users.kiosk = {
      isSystemUser = true;
      group = "kiosk";
      home = "/var/lib/kiosk";
      createHome = true;
      useDefaultShell = true;
      # evsieve opens the numpad itself (under sway, logind opened devices for
      # the compositor): without `input` it got "permission denied" and the
      # pad did nothing (stella, 2026-10-09, first Wayfire start).
      extraGroups = [ "input" ];
    };

    environment.systemPackages = [ kioskDesktop kioskBmc kioskWf ];
    # No "Save password?" bubble over the console (rack screen, 2026-10-09:
    # it popped up after the first automatic BMC login), no translate bar.
    programs.chromium = {
      enable = true;
      extraOpts = {
        PasswordManagerEnabled = false;
        TranslateEnabled = false;
        AutofillAddressEnabled = false;
        AutofillCreditCardEnabled = false;
        # No popups either (with --block-new-web-contents, kiosk-desktop.sh).
        DefaultPopupsSetting = 2;
      };
    };
    fonts.packages = [ pkgs.dejavu_fonts ];

    services.udev.packages = [ seatRules ];

    # The session: a logind session on seat1 (no virtual terminal there, so
    # it is active at once and never fights the console over tty1).
    security.pam.services.kiosk.startSession = true;
    systemd.services.kiosk = {
      description = "Rack kiosk (seat1, on the ${cfg.driver} card)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" "systemd-logind.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      # Stopped after the network on shutdown (stop order is the reverse of
      # `after`), so the logout still reaches the BMCs.
      restartIfChanged = false;
      environment = { XDG_SEAT = "seat1"; XDG_SESSION_TYPE = "wayland"; XDG_SESSION_CLASS = "user"; };
      serviceConfig = {
        User = "kiosk";
        PAMName = "kiosk";
        # logind puts the session's processes in a session scope, not in this
        # service (and Chromium makes its own scope): restarting the service
        # left the old Wayfire, evsieve (holding the pad) and Chromiums
        # (holding the profiles) alive, and the new session showed nothing
        # (stella, 2026-10-09). End every kiosk session before starting and
        # after logging out of the BMCs. "+" = as root, "-" = ignore failure.
        # terminate-user asks; it does not wait. A leftover that did not die
        # kept the old session "closing", and the new one never opened
        # (2026-10-09: a capture loop from a reverted version). Kill what is
        # left before opening the new session.
        ExecStartPre = [
          "-+${pkgs.systemd}/bin/loginctl terminate-user kiosk"
          "-+${pkgs.coreutils}/bin/sleep 2"
          "-+${pkgs.systemd}/bin/loginctl kill-user kiosk --signal=SIGKILL"
          "-+${screen}"
        ];
        ExecStart = session;
        ExecStop = logout;
        ExecStopPost = "-+${pkgs.systemd}/bin/loginctl terminate-user kiosk";
        TimeoutStopSec = 30;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # tty1 is a login prompt again (2026-10-12): kiosk-keys takes the rack
    # keyboard away from the console, so keys typed into the kiosk reach
    # stella only once, through its iKVM (face 3). Until 2026-10-12 tty1 showed
    # the journal read-only, because they also reached the console directly.
  }
  {
    # The cards plugged into this host: served here (modules/kiosk-capture.nix).
    labo.kioskCapture.cards = map (d: { inherit (d) name device; port = capturePort d; }) localCaptures;

    # The cards plugged into another host: one tunnel per host, run as the
    # kiosk user with its own key (seeded on the host, never in git:
    # ssh-keygen into ${tunnelKey}, kiosk 0600). The host key is pinned.
    programs.ssh.knownHosts = lib.mapAttrs' (h: key: lib.nameValuePair "kiosk-capture-${h}" {
      hostNames = [ "${h}.lab.example" ];
      publicKey = key;
    }) (lib.filterAttrs (h: _: lib.elem h captureHosts) cfg.captureHostKeys);
    systemd.services = lib.listToAttrs (map (h: lib.nameValuePair "kiosk-tunnel-${h}" {
      description = "SSH tunnel to the capture cards on ${h}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "kiosk";
        ExecStart = lib.concatStringsSep " " ([
          "${pkgs.openssh}/bin/ssh" "-N" "-i" tunnelKey
          "-o" "BatchMode=yes" "-o" "ExitOnForwardFailure=yes" "-o" "StrictHostKeyChecking=yes"
          "-o" "ServerAliveInterval=15" "-o" "ServerAliveCountMax=3"
        ] ++ lib.concatMap (d: [ "-L" "127.0.0.1:${toString (capturePort d)}:127.0.0.1:${toString (capturePort d)}" ])
          (lib.filter (d: d.host == h) remoteCaptures)
          ++ [ "kiosk-tunnel@${h}.lab.example" ]);
        Restart = "always";
        RestartSec = 15;
      };
    }) captureHosts);
  }
  ]);
}
