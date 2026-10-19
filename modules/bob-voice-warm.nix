# Hourly warm-up of Bob's VOICE prompt cache on bob, per Voice PE — worker2
# only (it has kp-get and the pinned Cloudflare Origin roots from ha-backup.nix).
# Why it cannot stay a Home Assistant automation: see bob-voice-warm.py.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  warm = pkgs.writeScript "bob-voice-warm" ''
    #!${py}/bin/python3
    ${builtins.readFile ./bob-voice-warm.py}
  '';
in
{
  systemd.services.bob-voice-warm = {
    description = "Warm Bob's voice prompt cache on bob, as each Voice PE builds it";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      KP_GET_BIN = "/usr/local/bin/kp-get";
      CF_ORIGIN_ROOTS = "/etc/ssl/certs/cloudflare-origin-roots.crt";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "ludorl82";      # kp-get reads ~ludorl82's KeePass password and key file
      TimeoutStartSec = "5min";
    };
    script = "exec ${warm}";
  };
  systemd.timers.bob-voice-warm = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:05:00";   # hourly; a cached context costs ~0.3 s
      Persistent = true;
      RandomizedDelaySec = "60";
    };
  };
}
