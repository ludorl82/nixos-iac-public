#!/usr/bin/env bash
# Seed (or re-seed) the console home directory on a fresh console-vm VM —
# the rebuild path that makes the console disposable. Run ON the new VM
# as ludorl82, after nixos-anywhere + first boot.
#
# Two sources, in order:
#   1. The nightly GPG tarball (secrets, dotfiles, .claude, .ssh, .cloud-01…)
#      from s3://homelab-backups-example-com/<prefix>/ — written by
#      scripts/homelab-backup.sh on the previous console/jumphost.
#   2. git clones for everything with a remote (the repo list below IS
#      the inventory — keep it current).
#
# Chicken-and-egg, documented not hidden: the tarball passphrase comes
# from kp-get, but kp-get needs ~/.keepass_password + the OneDrive
# keyfile, which are INSIDE the tarball. Break it one of two ways:
#   - run `ssh jumphost kp-get "Homelab Backup Passphrase"` (the jumphost
#     serves kp-get independently of this VM), or
#   - total-loss case: open the KeePass DB by hand (entry "Homelab
#     Backup Passphrase") and export PASSPHRASE before running this.
set -euo pipefail

BUCKET="homelab-backups-example-com"
PREFIX="${1:-pi-02}"   # first seed comes from the pi-02 series; after
                         # cutover the VM's own backups land in console-vm/
cd "$HOME"

if [ -z "${PASSPHRASE:-}" ]; then
  if command -v kp-get >/dev/null && [ -f "$HOME/.keepass_password" ]; then
    PASSPHRASE="$(kp-get "Homelab Backup Passphrase")"
  else
    PASSPHRASE="$(ssh -o ConnectTimeout=5 ludorl82@jumphost.lab.example 2>/dev/null)" || true
  fi
fi
if [ -z "${PASSPHRASE:-}" ]; then
  echo "No passphrase: export PASSPHRASE=... (KeePass entry 'Homelab Backup Passphrase') and rerun" >&2
  exit 1
fi

LATEST=$(cloud-01 s3 ls "s3://${BUCKET}/${PREFIX}/" | awk '{print $4}' | sort | tail -1)
[ -n "$LATEST" ] || { echo "no tarball under ${PREFIX}/" >&2; exit 1; }
echo "restoring ${PREFIX}/${LATEST}"
cloud-01 s3 cp "s3://${BUCKET}/${PREFIX}/${LATEST}" - \
  | gpg --batch --quiet --decrypt --passphrase-fd 3 3<<<"$PASSPHRASE" \
  | tar -xz -C "$HOME"
# /opt/scripts and the crontab snapshot land under ~/opt/... and ~/tmp;
# the jumphost, not the console, owns those — ignore them here.

# The repo inventory. Everything else in the old home was reproducible
# from these plus the tarball.
mkdir -p "$HOME/git/ludorl82"
clone() { [ -d "$2/.git" ] || git clone "git@github.com:ludorl82/$1.git" "$2"; }
clone nixos-iac        "$HOME/git/ludorl82/nixos-iac"
clone net-cfgs         "$HOME/git/ludorl82/net-cfgs"
clone k3s-iac          "$HOME/k3s-iac"
clone cloud-01-iac          "$HOME/cloud-01-iac"
clone cloudflare-iac   "$HOME/cloudflare-iac"
clone labodeludo.dev   "$HOME/labodeludo.dev"
clone nixos-iac        "$HOME/nixos-iac-deploy"   # a second working tree of nixos-iac, used for deploys
clone numeriseur-sftpgo "$HOME/numeriseur-sftpgo"
clone shell-scripts    "$HOME/.shell-scripts"
clone shell-configs    "$HOME/.shell-configs"

# Runtime copies the forced-command key on this host expects (the one
# :2222 Cronicle job runs ~/scripts/weekly-iac-updates.sh).
mkdir -p "$HOME/scripts"
cp "$HOME/git/ludorl82/nixos-iac/scripts/weekly-iac-updates.sh" "$HOME/scripts/"
chmod 700 "$HOME/scripts/weekly-iac-updates.sh"

echo "seeded. Sanity checks:"
ls -d "$HOME/.claude" "$HOME/.ssh" "$HOME/.cloud-01" 2>&1
command -v kp-get >/dev/null && kp-get "Homelab Backup Passphrase" >/dev/null && echo "kp-get OK"

cat <<'NEXT'
Next, INSIDE the console container (ssh -p 2222):
  ~/.shell-scripts/scripts/upgrade_console.sh
It installs the arch-correct Claude Code (deliberately not in this
tarball -- the binary is arch-specific) plus the zsh/tmux/nvim
environment.
NEXT
