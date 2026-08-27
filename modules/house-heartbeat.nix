# House half of the external dead-man's switch (cloud-01-iac live/deadman.tf) —
# pi-02 only. Writes deadman/house.heartbeat to S3 every 5 minutes;
# the out-of-VPC Lambda emails via SNS when it goes stale (>30 min).
#
# Moved here from a console-vm crontab (2026-08-04): pi-02 sits on the
# survivor UPS with the router and the WAN modem, so this heartbeat beats
# for exactly as long as the house can communicate at all — a stale
# heartbeat now means even the last-resort island is dark, the one
# situation where the SNS email adds information beyond Kuma/ntfy.
# (console-vm, by contrast, legitimately shuts down mid-drain at 10%
# battery, which would fire redundant emails during narrated outages.)
#
# Target bucket is deadman-example-com, NOT the backups bucket
# (moved 2026-08-05). This write overwrites the same key every 5 minutes,
# and Object Lock on a backups bucket cannot coexist with that: a locked
# version cannot be reclaimed by lifecycle, so the versions pile up for
# the whole retention period. See cloud-01-iac live/s3.tf.
#
# Credentials: /var/lib/house-heartbeat/cloud-01-env is seeded OUT-OF-BAND
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION for the shared
# homelab-backup IAM user, which now carries a separate
# deadman-heartbeat-write policy for the new bucket). Unchanged by the
# move — same user, same file. The service fails loudly without it.
{ config, pkgs, lib, ... }:
{
  systemd.services.house-heartbeat = {
    description = "Dead-man house heartbeat to S3";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "house-heartbeat";
      EnvironmentFile = "/var/lib/house-heartbeat/cloud-01-env";
    };
    script = ''
      date -u +%FT%TZ | ${pkgs.awscli2}/bin/cloud-01 s3 cp - \
        s3://deadman-example-com/deadman/house.heartbeat --quiet
    '';
  };
  systemd.timers.house-heartbeat = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      AccuracySec = "30s";
    };
  };

  # Kuma push monitor 53: a per-minute pulse from the island to Kuma on
  # the cloud-01 node. One probe exercises the whole survivor stack — pi-02,
  # the SG-1100 OPT link, pfSense, the WAN modem — so "no pulse for 3 min"
  # means the island cannot communicate. Complements (not replaces) the
  # dead-man house heartbeat above: Kuma alerts in ~3 min via ntfy, the
  # Lambda emails at ~45 min via a path that shares nothing with either.
  systemd.services.survivor-pulse = {
    description = "Survivor-island pulse to Uptime Kuma";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.curl}/bin/curl -fsS -m 10 \
        "http://198.51.100.7:3001/api/push/EXAMPLEPUSHTOKEN?status=up&msg=OK" \
        > /dev/null || true
    '';
  };
  systemd.timers.survivor-pulse = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "10s";
    };
  };
}
