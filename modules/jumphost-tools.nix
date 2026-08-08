# Credential/tooling surface shared by the jumphost (pi-02) and the
# console (the console-vm VM on gpu-01) — the "access parity" half of the
# 2026-08-07 jumphost/console split. Everything here is read-only or
# host-local: no listeners, no singletons, safe to run on any number of
# hosts concurrently. The singletons and the service-key surface live in
# jumphost.nix, which imports this.
#
# Out-of-band expectations (ride the home directory / S3 seed):
#   ~/.keepass_password                          — kp-get master password
#   ~/OneDrive/Documents/Certificats/ludovic-2.key — kp-get keyfile
{ config, pkgs, lib, ... }:
let
  kpGet = import ./kp-get.nix { inherit pkgs; };
in
{
  environment.systemPackages = [
    kpGet
    # google-api-python-client + google-auth-oauthlib drive the Gmail-filter
    # phase of process_keepass.py (and gmail_bootstrap.py, which mints the
    # per-account tokens). The script guards its google imports and merely
    # logs-and-skips when they are missing, which is exactly how that phase
    # stayed silently dead from the console-vm→pi-02 cutover (2026-08-05)
    # until b1f007f — the cutover assumed these wheels wouldn't build on
    # aarch64; they come straight from cache.nixos.org.
    (pkgs.python3.withPackages (ps: [
      ps.pykeepass ps.boto3 ps.requests
      ps.google-api-python-client ps.google-auth-oauthlib
    ]))
    # homelab-backup.sh needs gpg + cloud-01, wan-ip/weekly scripts need awscli.
    pkgs.gnupg
    pkgs.awscli2
    pkgs.jq
    # seed-console-home.sh clones the repo inventory on the HOST (git
    # normally only exists inside the console container).
    pkgs.git
  ];

  systemd.tmpfiles.rules = [
    # The forced-command keys and every script reference the console-vm-era
    # absolute path.
    "L+ /usr/local/bin/kp-get - - - - ${kpGet}/bin/kp-get"
    # Restored scripts carry #!/bin/bash shebangs from Debian console-vm;
    # NixOS only provides /bin/sh (same fix as hosts/cloud-01).
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    # process_keepass.py logs here; pre-existed writable on console-vm, NixOS
    # must declare it (same lesson as cloud-01's homelab_backup.log).
    "f /var/log/keepass_domain_hash.log 0644 ludorl82 users -"
  ];
}
