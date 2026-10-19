## The host side of Frigate: what the Frigate pod (k3s-iac frigate/, a
## hostNetwork pod pinned by nodeSelector) needs from the node it runs on.
## Import it on exactly ONE host, the one the pod's nodeSelector names.
##
## Moved from hosts/encodeur to this module on 2026-10-17, when Frigate went
## to luna (RTX 3050 on the host). The data is a plain directory here,
## /home/ludorl82/opt/frigate (config, ~78 GB of recordings, frigate.db, the
## side-car scripts), copied over from encodeur's frigate-lv; it is not a
## mount, so nothing below orders on a .mount unit.
{ lib, pkgs, ... }:
let
  dir = "/home/ludorl82/opt/frigate";
in
{
  ## Frigate runs with hostNetwork, so its ports are bound on the node's own
  ## VLAN10 address and every consumer reaches them over the LAN, NOT through
  ## the pod network - the k3s-agent module's trustedInterfaces (cni0,
  ## flannel.1) do NOT cover this. That includes Traefik: the frigate Service
  ## endpoint resolves to the node's IP:5000, off-cluster as far as routing
  ## is concerned, so frigate.lab.example just hangs unless 5000 is open here.
  ##   5000 api/UI, 1984 go2rtc, 8554 RTSP (HA + the low-res feed),
  ##   8555 WebRTC (tcp+udp).
  networking.firewall = {
    allowedTCPPorts = [ 5000 1984 8554 8555 ];
    allowedUDPPorts = [ 8555 ];
  };

  ## --- Side-cars (were plain systemd + crontab on Ubuntu) ----------------
  ##
  ## The shell/python jobs deliberately stay in ${dir}/scripts rather than in
  ## the nix store: operational scripts edited in place, with the Kuma push
  ## tokens inside them. Only the schedule and the environment are declared.

  ## Long-term low-res archive feed: re-encodes the ad410-avant RTSP stream
  ## to a tiny 640x480 h264_nvenc segment every 5 min, which aws pulls to S3
  ## (hosts/aws/scripts/sync_frigate_lowres.py). Reads Frigate's own go2rtc
  ## on localhost, so it just retries until the pod is up.
  systemd.services.frigate-lowres-feed = {
    description = "Low-res long-term video feed for ad410-avant (S3 archive source)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    ## No data dir (host freshly set up, copy not done yet) = do nothing
    ## rather than crash-loop.
    unitConfig.ConditionPathIsDirectory = "${dir}/lowres/ad410-avant";
    serviceConfig = {
      User = "ludorl82";
      Restart = "always";
      RestartSec = 5;
    };
    ## nvenc is dlopen'd (libnvidia-encode.so.1); on NixOS it only exists
    ## under /run/opengl-driver/lib, not on a unit's default loader path.
    ## TZ: the segment names are strftime'd in local time (as on encodeur,
    ## whose host clock was America/Toronto); the host itself may stay UTC.
    environment = {
      LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      TZ = "America/Toronto";
    };
    ## A script (not a raw ExecStart=) so the strftime pattern needs no
    ## %%-escaping for systemd.
    script = ''
      exec ${pkgs.ffmpeg-full}/bin/ffmpeg -rtsp_transport tcp \
        -i rtsp://127.0.0.1:8554/ad410-avant \
        -vf scale=640:480 -c:v h264_nvenc -b:v 120k -maxrate 150k \
        -bufsize 300k -an \
        -f segment -segment_time 300 -segment_format mp4 \
        -reset_timestamps 1 -strftime 1 \
        ${dir}/lowres/ad410-avant/%Y%m%d_%H%M%S.mp4
    '';
  };

  ## Sub-hourly jobs stay in host cron on purpose - they were deliberately
  ## moved back OUT of Cronicle, which only holds daily/weekly work. cron
  ## hands each line to sh with a near-empty PATH, so every job gets one.
  ## Minute-based schedules, so the host's timezone does not matter.
  services.cron = {
    enable = true;
    systemCronJobs =
      let
        binPath = lib.makeBinPath [
          pkgs.bash pkgs.coreutils pkgs.curl pkgs.rsync pkgs.openssh
          pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.util-linux
          pkgs.systemd pkgs.python3
        ];
        s = "${dir}/scripts";
      in [
        "*/5  * * * * root      PATH=${binPath} ${pkgs.python3}/bin/python3 ${s}/frigate_recording_watchdog.py >> /var/log/frigate_recording_watchdog.log 2>&1"
        "*/10 * * * * ludorl82  PATH=${binPath} ${s}/lowres_feed_watchdog.sh"
        "15   * * * * ludorl82  PATH=${binPath} ${s}/backup_to_nas.sh >> ${s}/backup_to_nas.log 2>&1"
        "20   * * * * ludorl82  PATH=${binPath} ${s}/prune_lowres.sh"
      ];
  };

  ## aws pulls the low-res segments off this host (rsync over ssh, as
  ## ludorl82, key /root/.ssh/id_ed25519_encodeur_pull on aws).
  users.users.ludorl82.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
  ];
}
