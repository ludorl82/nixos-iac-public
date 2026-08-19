# Off-box copy of ha-01's Home Assistant backups — pi-02 only.
#
# WHY THIS EXISTS. ha-01 is the one box whose config lives nowhere but
# on the box: the `.storage` half (integration config entries, registries,
# auth, the Ollama agent subentry) cannot be rebuilt from code, and until
# 2026-08-05 it was protected nowhere. HA *was* making a correct encrypted
# daily backup all along — it just never left the box. Its backup config
# targeted two agents, `hassio.local` and `cloud.cloud`, and the cloud one
# failed every single night since 2026-02-23. The local half kept
# succeeding, so nothing surfaced; `last_completed_automatic_backup` sat
# frozen for six months while retention quietly held the window at 3 copies,
# all on the same disk. That is the failure mode this module answers: not
# "no backups", but "no backup ever left, and nothing said so".
#
# So it PULLS rather than letting HA push, and it reports to Kuma (monitor
# 55, ha-01-ha-backup) on both success and failure. A puller that
# heartbeats cannot fail the same quiet way — a missed day pages via ntfy.
#
# Cronicle drives it on the daily/weekly convention (net-cfgs), SSHing in on
# the forced-command key declared in modules/console-host.nix, exactly like
# homelab-backup.sh. Nothing new is scheduled on the host itself.
#
# NOT gpg-wrapped, deliberately, unlike homelab-backup.sh. HA backups are
# already AES-encrypted with the backup password when protected=true, and
# ha-backup.py refuses to ship one that isn't. Wrapping again would buy
# nothing and add a second passphrase to lose. The consequence is worth
# stating plainly: the KeePass entry holding the HA backup password is the
# only thing standing between these S3 objects and a restore. That entry is
#
#     "Automatron Encryption key (claudecode)"
#
# and it was verified on 2026-08-05 against the first shipped object: the
# securetar archive decrypts and yields data/.storage/core.config_entries,
# core.device_registry, core.entity_registry, core.area_registry and auth —
# i.e. exactly the half that cannot be rebuilt from code. Re-verify after
# any HA-side change to the encryption key, because nothing here would
# notice: a backup encrypted with a rotated key ships and validates
# identically right up until someone needs it.
{ config, pkgs, lib, ... }:
let
  # websockets: HA's backup control plane (backup/info) is websocket-only.
  # The Supervisor REST proxy at /api/hassio/ would also list backups, but
  # core returns 401 there for long-lived tokens — don't go back down that
  # road, the websocket API is the supported path for an LLAT.
  haPython = pkgs.python3.withPackages (ps: [ ps.websockets ]);

  # The .py keeps its own `#!/usr/bin/env python3` so it stays runnable and
  # lintable on its own; as the second line of the generated script it is
  # just a Python comment.
  haBackupRaw = pkgs.writeScriptBin "ha-backup-raw" ''
    #!${haPython}/bin/python3
    ${builtins.readFile ./ha-backup.py}
  '';

  # Wrapper pins the tool paths: the script runs from a forced-command SSH
  # session, which has close to no PATH.
  haBackup = pkgs.writeShellScriptBin "ha-backup" ''
    export AWS_BIN=${pkgs.awscli2}/bin/cloud-01
    export KP_GET_BIN=/usr/local/bin/kp-get
    export CF_ORIGIN_ROOTS=/etc/ssl/certs/cloudflare-origin-roots.crt
    export KUMA_PUSH_URL=http://198.51.100.7:3001/api/push/EXAMPLEPUSHTOKEN
    exec ${haBackupRaw}/bin/ha-backup-raw "$@"
  '';
in
{
  environment.systemPackages = [ haBackup ];

  # Cloudflare's Origin CA roots, pinned as the trust anchor for ha-01.
  #
  # ha-01 serves a Cloudflare Origin certificate whose SANs are
  # *.family.example and family.example — it does NOT cover ha-01-local.lab.example,
  # the name it actually answers to on VLAN10. An Origin cert is only ever
  # trusted by Cloudflare's edge, so no public root validates it either.
  # ha-backup.py therefore dials the box's IP while presenting and verifying
  # the name the cert really carries, against these roots. That is real
  # verification (see net-cfgs: TLS verification, no shortcuts) — it is not
  # verify=False wearing a hat, and it must not be "simplified" to -k.
  #
  # The honest fix is a private-CA leaf for ha-01-local.lab.example via
  # modules/private-ca.nix, which would delete this whole workaround. Until
  # then this is the seam. Public certs, safe to commit.
  environment.etc."ssl/certs/cloudflare-origin-roots.crt".source =
    ./cloudflare-origin-roots.crt;
}
