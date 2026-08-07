# Wake the QNAP NAS after a power event (pi-01 only — the NAS shares
# pi-01's UPS). Companion to modules/ups-master.nix and the QNAP's NUT
# network-client subscription: on battery the NAS shuts down *cleanly*
# after 5 min, which means its "restore previous state" power recovery
# sees a clean OFF and leaves it off when the mains return. This closes
# that gap with Wake-on-LAN (already armed on the NAS NIC, Wake-on: g).
#
# Deliberately a latched state machine, not a bare "wake if down" loop —
# a NAS the user shut down on purpose must stay down:
#   - UPS reports On Battery  -> latch a flag (persists across reboots,
#     including pi-01 itself dying at battery exhaustion)
#   - UPS back OnLine + flag  -> send magic packets each minute until the
#     NAS answers ping, then clear the flag and tell ntfy
# Magic packets go to both broadcast domains on the trunk (untagged
# VLAN50 + tagged VLAN10); a booting/running NAS ignores extras.
{ config, pkgs, lib, ... }:
let
  nasMac = "02:00:00:00:00:01"; # eth0 (physical) on nas
  nasIp = "192.0.2.65";
  flag = "/var/lib/nas-wake/armed";
in
{
  systemd.services.nas-wake = {
    description = "Wake NAS by WoL after UPS power restore";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "nas-wake";
    };
    script = ''
      status=$(${pkgs.nut}/bin/upsc qnapups ups.status 2>/dev/null || echo UNKNOWN)
      case " $status " in
        *" OB"*|*"OB "*)
          if [ ! -e ${flag} ]; then
            touch ${flag}
            echo "on battery: armed NAS wake latch"
          fi
          ;;
        *" OL"*|*"OL "*)
          [ -e ${flag} ] || exit 0
          if ${pkgs.iputils}/bin/ping -c1 -W2 ${nasIp} > /dev/null 2>&1; then
            rm -f ${flag}
            echo "power restored and NAS reachable: latch cleared"
            ${pkgs.curl}/bin/curl -fsS -m 10 \
              -H "Authorization: Bearer tk_olpt3n3jrp91acdq7f9ffc5esuemd" \
              -H "Title: NAS back after power event" \
              -H "Tags: electric_plug" \
              -d "UPS online and nas answers ping again; wake latch cleared." \
              https://ntfy.pub.example.com/alerts || true
          else
            echo "power restored, NAS down: sending WoL"
            ${pkgs.wol}/bin/wol -i 203.0.113.255 ${nasMac}
            ${pkgs.wol}/bin/wol -i 192.0.2.255 ${nasMac}
            ${pkgs.wol}/bin/wol -i 192.0.2.255 ${nasMac}
          fi
          ;;
      esac
    '';
  };
  systemd.timers.nas-wake = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "10s";
    };
  };
}
