# Rolling-rack wake orchestrator — pi-02 only. pi-02 + the pfSense
# SG-1100 live on the bottom OR700 (~15 W combined, hours of runtime): the
# "survivor" pair that outlasts any realistic outage. gpu-01's UPS
# deliberately does NOT killpower (its LX1500GU never auto-restores
# output; see hosts/gpu-01), so after a rolling-rack drain the four servers
# sit in soft-off with their BMCs still powered — and this latch brings
# them back when the mains return.
#
# Same latched design as nas-wake: a real power event arms it; a host the
# user shut down on purpose during normal times is never touched.
#   - own UPS (house mains sensor) reports OB  -> arm /var/lib/rack-wake/armed
#   - OL + armed -> for each BMC: chassis power status == off -> power on.
#     Gating on the BMC's chassis state (not OS ping) means a host still
#     mid-shutdown (chassis on) is left alone and picked up next minute.
#   - all four chassis on -> disarm + ntfy.
#
# IPMI credentials: one password file per BMC under /var/lib/rack-wake/
# (ipmi-gpu-01, ipmi-hyperv-host, ipmi-srv-01, ipmi-gpu-02), root 600,
# seeded OUT-OF-BAND from the KeePass IPMI entries. Missing file = that
# BMC is skipped with a log line, not a crash.
{ config, pkgs, lib, ... }:
let
  flag = "/var/lib/rack-wake/armed";
  bmcs = [
    { name = "gpu-01"; ip = "192.0.2.5"; }
    { name = "hyperv-host"; ip = "192.0.2.6"; }
    { name = "srv-01"; ip = "192.0.2.7"; }
    { name = "gpu-02"; ip = "192.0.2.8"; }
  ];
  ipmi = "${pkgs.ipmitool}/bin/ipmitool";
  checkOne = b: ''
    pw=/var/lib/rack-wake/ipmi-${b.name}
    if [ ! -s "$pw" ]; then
      echo "rack-wake: no credential for ${b.name}, skipping"
    else
      status=$(IPMI_PASSWORD=$(cat "$pw") ${ipmi} -I lanplus -H ${b.ip} -U ADMIN -E chassis power status 2>/dev/null || echo unreachable)
      case "$status" in
        *off)
          echo "rack-wake: powering on ${b.name}"
          IPMI_PASSWORD=$(cat "$pw") ${ipmi} -I lanplus -H ${b.ip} -U ADMIN -E chassis power on || true
          all_on=0
          ;;
        *on) ;;
        *)
          echo "rack-wake: ${b.name} BMC unreachable"
          all_on=0
          ;;
      esac
    fi
  '';
in
{
  systemd.services.rack-wake = {
    description = "IPMI-wake the rolling rack after UPS power restore";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "rack-wake";
    };
    script = ''
      status=$(${pkgs.nut}/bin/upsc qnapups ups.status 2>/dev/null || echo UNKNOWN)
      case " $status " in
        *" OB"*|*"OB "*)
          if [ ! -e ${flag} ]; then
            touch ${flag}
            echo "on battery: armed rolling-rack wake latch"
          fi
          exit 0
          ;;
        *" OL"*|*"OL "*) ;;
        *) exit 0 ;;
      esac
      [ -e ${flag} ] || exit 0
      all_on=1
      ${lib.concatMapStrings checkOne bmcs}
      if [ "$all_on" = 1 ]; then
        rm -f ${flag}
        echo "power restored and all rolling-rack chassis on: latch cleared"
        ${pkgs.curl}/bin/curl -fsS -m 10 \
          -H "Authorization: Bearer tk_olpt3n3jrp91acdq7f9ffc5esuemd" \
          -H "Title: Rolling rack awake after power event" \
          -H "Tags: electric_plug" \
          -d "Mains back; all four chassis report power on. rack-wake latch cleared." \
          https://ntfy.pub.example.com/alerts || true
      fi
    '';
  };
  systemd.timers.rack-wake = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "10s";
    };
  };
}
