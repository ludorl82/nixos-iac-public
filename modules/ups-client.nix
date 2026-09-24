# NUT network client (upsmon secondary) for hosts that draw from the
# rolling-rack UPS but don't hold its USB cable: gpu-02 and srv-01.
# gpu-01 is the cp-1 (modules/ups-cp-1.nix); at low battery gpu-01's upsd
# broadcasts FSD, the secondaries here shut down cleanly first, then gpu-01
# follows. The BMC power-restore policy on all these boards is always-on
# (set 2026-08-04), so everything returns by itself with the mains.
#
# Credentials: /var/lib/nut/monclient-password is seeded OUT-OF-BAND and
# must be byte-identical to the cp-1's copy — generate once, `sudo tee`
# on gpu-01 + every client. upsmon refuses to start without it, which is the
# desired failure mode: silent no-protection is worse than a red unit.
#
# srv-01 note: its libvirt VMs (k3s workers) are covered by the host's
# ordinary shutdown sequence — libvirt-guests handles them before the
# host goes down.
{ config, pkgs, lib, ... }:
let
  clientPasswordFile = "/var/lib/nut/monclient-password";

  # Same ntfy hook as ups-cp-1.nix: ONLINE/COMMOK resolve, rest is high.
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
    mode = "netclient";

    upsmon = {
      monitor.qnapups = {
        system = "qnapups@192.0.2.129"; # gpu-01, the rolling-rack cp-1
        user = "monclient";
        passwordFile = clientPasswordFile;
        powerValue = 1;
        type = "secondary";
      };
      settings = {
        MINSUPPLIES = 1;
        NOTIFYCMD = "${notifyScript}";
        NOTIFYFLAG = map (t: [ t "SYSLOG+EXEC" ]) [
          "ONLINE" "ONBATT" "LOWBATT" "FSD" "COMMOK" "COMMBAD"
          "SHUTDOWN" "REPLBATT" "NOCOMM" "NOPARENT"
        ];
      };
    };
  };
}
