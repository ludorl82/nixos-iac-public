# Ships console-vm's logs to Loki — the host journal, and the log file every
# console job writes for each run.
#
# WHY (2026-09-16). The k3s Alloy DaemonSet collects the journal of every
# cluster node and the output of every pod. console-vm is not a node — it is the
# console VM — so nothing it logged reached Loki: its `host` label simply did
# not exist there. And the five jobs Cronicle runs on it over ssh
# (nightly-diagram-sync, daily-gpu-01-sync via arch-refresh, the drift dispatch,
# the snapshot publish, the IaC update PRs) wrote their output only to the
# Cronicle job log. That store lost a whole run the same day, when the cronicle
# Deployment was replaced mid-run: `cronicle/jobs/jmu4idh03ge: Not found`.
#
# Since then every console job writes its own log file (run-from-cp-1.sh), in
# a detached process that outlives the ssh carrying it. This ships those files
# as they are written — so even a run whose caller vanished is readable in
# Grafana, line by line, up to the moment it stopped.
#
# LABELS MIRROR THE DAEMONSET: `host`, and `unit` for journal lines, so one
# Grafana query shape covers the whole fleet. File lines carry `job` (the
# script's name, from its directory) and Alloy's own `filename`, which is one
# run.
#
# Plain HTTP to loki.lab.example, the same endpoint the out-of-cluster collector
# used before the fleet moved into k3s. It is on the lab network and carries no
# credentials.
{ ... }:

let
  jobsDir = "/home/ludorl82/.local/state/jobs";
  # Where the unit sees that directory. The home is 0700 and Alloy runs as a
  # DynamicUser, so it cannot walk to the files where they live; systemd mounts
  # exactly this one directory, read-only, somewhere it can.
  jobsView = "/run/console-jobs";
in
{
  services.alloy.enable = true;

  environment.etc."alloy/config.alloy".text = ''
    loki.write "default" {
      endpoint {
        url = "http://loki.lab.example/loki/api/v1/push"
      }
    }

    // ---- host journal — same rules as the k3s DaemonSet ----
    loki.relabel "journal" {
      forward_to = []
      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
      // one stream per ssh login would exhaust the stream limit
      rule {
        source_labels = ["unit"]
        regex         = "session-[0-9]+\\.scope"
        target_label  = "unit"
        replacement   = "session.scope"
      }
    }

    loki.source.journal "read" {
      forward_to    = [loki.write.default.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = { host = "console-vm" }
    }

    // ---- console job runs: ${jobsDir}/<job>/<run>.log ----
    local.file_match "jobs" {
      path_targets = [{
        "__path__" = "${jobsView}/*/*.log",
        host       = "console-vm",
      }]
    }

    discovery.relabel "jobs" {
      targets = local.file_match.jobs.targets
      rule {
        source_labels = ["__path__"]
        regex         = "${jobsView}/([^/]+)/[^/]+\\.log"
        target_label  = "job"
      }
    }

    loki.source.file "jobs" {
      targets    = discovery.relabel.jobs.output
      forward_to = [loki.write.default.receiver]
    }
  '';

  # The directory must exist before the unit starts, or the bind mount fails
  # the unit outright. The console user owns it; Alloy only ever reads.
  systemd.tmpfiles.rules = [ "d ${jobsDir} 0755 ludorl82 users -" ];

  systemd.services.alloy = {
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig.BindReadOnlyPaths = [ "${jobsDir}:${jobsView}" ];
  };
}
