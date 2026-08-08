# NUT master for a directly-attached CyberPower UPS (USB HID). Imported by
# pi-01 (top wall-rack OR700), pi-02 (second OR700) and gpu-01 (rolling-rack
# LX1500GU). Each host is the NUT *master* for the UPS on its own USB port —
# note pi-02 draws power from pi-01's UPS but monitors the other one;
# NUT doesn't care, and during a house outage pi-02 (battery-backed
# outlet) still narrates. Trust ups.model over lsusb: the shared CyberPower
# USB ids lie about the model (0764:0601 claims PR1500, is OR700).
#
# The UPS is deliberately named "qnapups": QNAP's built-in NUT network
# client can only subscribe to a UPS with that exact name, and the NAS
# will be pointed at the master of whichever UPS feeds it so it can shut
# down cleanly on battery (the 2026-08-03 outage lesson).
#
# upsd listens on VLAN10 (:3493, firewall opened) for that client and for
# ad-hoc `upsc qnapups@workerN` reads. Credentials: a random password is
# generated on first activation into /var/lib/nut/upsd-password — nothing
# secret in the repo; read it off the host when enrolling the QNAP.
#
# Alerting: every upsmon event (ONBATT/LOWBATT/REPLBATT/COMMBAD/...) goes
# to ntfy /alerts with a dedicated write-only token, alongside syslog.
# Metrics: a 1-minute timer logs the full `upsc` variable dump to journald
# as one logfmt line (unit ups-metrics) for Loki/ad-hoc forensics — two
# independent input-voltage sensors for the house.
{ config, pkgs, lib, ... }:
let
  passwordFile = "/var/lib/nut/upsd-password";
  clientPasswordFile = "/var/lib/nut/monclient-password";

  # upsmon calls NOTIFYCMD with the human message as $1 and UPSNAME /
  # NOTIFYTYPE in the environment. ONLINE/COMMOK resolve incidents, so
  # they go out at default priority; everything else is high.
  notifyScript = pkgs.writeShellScript "nut-ntfy" ''
    case "$NOTIFYTYPE" in
      ONLINE|COMMOK) priority=default ;;
      *)             priority=high ;;
    esac
    ${pkgs.curl}/bin/curl -fsS -m 10 \
      -H "Authorization: Bearer tk_olpt3n3jrp91acdq7f9ffc5esuemd" \
      -H "Title: UPS $NOTIFYTYPE: $UPSNAME@$(${pkgs.nettools}/bin/hostname)" \
      -H "Priority: $priority" \
      -H "Tags: electric_plug" \
      -d "''${1:-$NOTIFYTYPE}" \
      https://ntfy.pub.example.com/alerts || true
  '';
in
{
  power.ups = {
    enable = true;
    mode = "netserver";
    openFirewall = true;

    ups.qnapups = {
      driver = "usbhid-ups";
      port = "auto";
      description = "CyberPower UPS on ${config.networking.hostName}";
      # Be explicit that a killpower shutdown must use "turn off the load
      # and RETURN when power is back" — not stayoff. Drill #2: after a
      # full power-off the LX did not visibly restore output on AC return
      # (button press beat the possible 120 s + charge-gated auto-restart);
      # no auto-restart EEPROM toggle exists over USB, so return semantics
      # in the shutdown command is all the leverage we have.
      directives = [ "sdcommands = shutdown.return" ];
    };

    upsd.listen = [
      { address = "0.0.0.0"; }
      { address = "::"; }
    ];

    users.monuser = {
      passwordFile = passwordFile;
      upsmon = "primary";
    };

    # Remote upsmon secondaries (modules/ups-client.nix on hosts sharing
    # this UPS) log in as monclient. The password file is seeded
    # OUT-OF-BAND, identically on the master and every client — generate
    # once, `sudo tee /var/lib/nut/monclient-password` everywhere. upsd
    # counts logged-in secondaries and holds its own FSD shutdown until
    # they have gone down.
    users.monclient = {
      passwordFile = clientPasswordFile;
      upsmon = "secondary";
    };

    upsmon = {
      monitor.qnapups = {
        user = "monuser";
        inherit passwordFile;
        powerValue = 1;
        type = "primary";
      };
      settings = {
        MINSUPPLIES = 1;
        NOTIFYCMD = "${notifyScript}";
        NOTIFYFLAG = map (t: [ t "SYSLOG+EXEC" ]) [
          "ONLINE" "ONBATT" "LOWBATT" "FSD" "COMMOK" "COMMBAD"
          "SHUTDOWN" "REPLBATT" "NOCOMM" "NOPARENT"
        ];
        # Set by upsmon when this shutdown is UPS-driven (FSD/low battery);
        # the systemd.shutdown hook below only acts when it exists.
        POWERDOWNFLAG = "/run/killpower";
      };
    };
  };

  # 2026-08-04 drill lesson: hosts shut down cleanly but the UPS kept its
  # outlets hot (mains returned before the battery died), so the BMCs saw
  # no AC-loss event and their always-on policy never fired — the rack sat
  # in soft-off. Fix: as the very last act of a UPS-driven poweroff, tell
  # the UPS to cycle its own output (~1 min off, back once mains present).
  # That guarantees the AC transition the BMCs key on, drill or real.
  # Guarded: only on poweroff/halt, only when upsmon left POWERDOWNFLAG.
  systemd.shutdown."nut-killpower" = pkgs.writeShellScript "nut-killpower" ''
    [ "$1" = "poweroff" ] || [ "$1" = "halt" ] || exit 0
    [ -e /run/killpower ] || exit 0
    echo "nut-killpower: UPS-driven shutdown - commanding UPS output cycle"
    export NUT_CONFPATH=/etc/nut
    ${pkgs.nut}/bin/upsdrvctl -u root shutdown || true
  '';

  # First-boot credential generation. root:nut 640 so upsd (running as
  # nut) can read it but network peers can't; survives redeploys.
  system.activationScripts.nut-upsd-password = ''
    install -d -m 750 /var/lib/nut
    if [ ! -s ${passwordFile} ]; then
      tr -dc A-Za-z0-9 < /dev/urandom | head -c 32 > ${passwordFile}
    fi
    chown root:nut ${passwordFile} 2>/dev/null || true
    chmod 640 ${passwordFile}
    # upsd refuses to start if any user's password file is missing
    # (systemd LoadCredential, status 243) — which silently took the Pi
    # masters down when monclient was added (2026-08-04). A random
    # placeholder keeps upsd up on masters that have no secondaries yet;
    # masters WITH secondaries must overwrite it with the shared
    # out-of-band monclient secret.
    if [ ! -s ${clientPasswordFile} ]; then
      tr -dc A-Za-z0-9 < /dev/urandom | head -c 32 > ${clientPasswordFile}
    fi
    chown root:root ${clientPasswordFile}
    chmod 600 ${clientPasswordFile}
  '';

  systemd.services.ups-metrics = {
    description = "Log UPS variables to journald (logfmt)";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.nut}/bin/upsc qnapups 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F': ' '{printf "%s=\"%s\" ", $1, $2} END {print ""}'
    '';
  };
  systemd.timers.ups-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "5s";
    };
  };
}
