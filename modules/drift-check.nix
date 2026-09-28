# Nightly configuration-revision drift check (Cronicle event "nixos-iac Drift
# Check"). A locked-down user whose key is bound to a single forced command:
# report which git revision built the running system. The checker compares
# every host's answer against origin/cp-1 HEAD and alerts through Kuma/ntfy
# when a host runs stale (or dirty-tree) config.
#
# configurationRevision itself is set flake-side (the inline driftModule in
# flake.nix) because it needs self.rev. Until a host is redeployed with that
# change it reports nothing and the check flags it as unverifiable — expected
# on first rollout.
#
# The private key lives only in the cronicle namespace Secret
# cronicle-ssh-nixos-drift (out-of-band, like every other cronicle-ssh-*).
#
# --------------------------------------------------------------------------
# A SECOND VERB, NOT A SECOND KEY (2026-09-16)
# --------------------------------------------------------------------------
#
# `labo.gpus` moved the fleet's graphics cards out of prose and into a field,
# and emit-fleet.py now refuses to publish an inventory that disagrees with
# it. That closes the gap between the DECLARATION and what gets published. It
# says nothing about whether the declaration matches the metal — somebody
# still has to edit it when a card goes in, and forgetting to is the failure
# that started all this on 2026-09-14.
#
# So the machines get a say. `gpus` returns what lspci sees, and
# scripts/gpu-discovery.py compares it against what the repo declares.
#
# DISCOVERY IS A THIRD OPINION, NEVER THE SOURCE. An inventory built from live
# hosts publishes "no cards" for every machine that happens to be asleep — in
# silence, and with the authority of a measurement. gaming-01's gaming guests are
# off almost always by design and vm-03 is an on-demand node, so that is not
# a corner case here, it is most nights. The declaration works when the metal
# is dark; the metal catches a declaration nobody updated. Neither can do the
# other's job, which is the same shape as check-openers.py and
# check-answerable.py on the site.
#
# WHY lspci AND NOT nvidia-smi. gaming-01 has three cards and no `nvidia-smi` at
# all: all six PCI functions are bound to vfio-pci for its guests, so the host
# drives none of them and has no reason to carry the tool. A driver-level
# probe would report zero cards on the one machine this check exists for.
# lspci reads the bus, so it sees a card whatever owns it — verified on all
# three GPU hosts on 2026-09-16.
#
# ONE KEY, TWO VERBS, dispatched on SSH_ORIGINAL_COMMAND — the pattern already
# used by claude-ctl on console-vm, arcade-ctl on gaming-01 and power-ctl on
# pi-02. A second keypair would mean another out-of-band Secret to create,
# rotate and eventually lose.
#
# That backward compatibility is load-bearing, and it took two tries. The
# Cronicle drift check calls `ssh … driftcheck@$h.lab.example true` — a word that
# was inert while the forced command ignored SSH_ORIGINAL_COMMAND, and became
# an unknown verb the moment it did not. The first version of this shipped
# with "the existing check keeps working untouched" written here and no test
# behind the sentence; the live probe answered "denied" from all three hosts.
# `revision`, `true` and the empty command all print the revision, and
# scripts/tests/drift-ctl-test.sh runs the real dispatcher for each of them.
{ lib, pkgs, ... }:

let
  # No sudo, no setuid, nothing privileged: lspci reads the PCI bus as any
  # user. Board models and serials would need root, and that is a different
  # conversation than this one.
  driftCtl = pkgs.writeShellScript "drift-ctl" ''
    export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.pciutils ]}:/run/current-system/sw/bin
    set -- $SSH_ORIGINAL_COMMAND
    case "''${1:-revision}" in
      # `true` is not decoration. The Cronicle drift check has always called
      # `ssh … driftcheck@$h.lab.example true`, because the old forced command
      # ignored SSH_ORIGINAL_COMMAND entirely and the word was inert. Giving
      # the command meaning gave that word meaning too, and the first live
      # probe after deploying came back "denied" from all three hosts — which
      # would have turned every host "unverifiable" at 04:31 and pushed Kuma 42
      # red. Backward compatibility was claimed here before it was checked;
      # this is the check.
      revision|true)
        # Byte-identical to what this key did before the second verb existed.
        exec nixos-version --configuration-revision
        ;;
      gpus)
        # `lspci -n` prints "SLOT CLASS: VENDOR:DEVICE (rev NN)". Class 03xx is
        # a display controller; the card's own HDMI audio function is 0403 and
        # is deliberately dropped — it is the same physical card, and counting
        # it would double every entry.
        #
        # One JSON object per line rather than one array: a truncated stream
        # then loses a card instead of the whole report, and the reader can
        # say which line it could not parse.
        lspci -n -d 10de: | awk '$2 ~ /^03/ {
          printf "{\"slot\": \"%s\", \"id\": \"%s\"}\n", $1, $3
        }'
        ;;
      *)
        echo "denied: drift-ctl knows 'revision' and 'gpus'" >&2
        exit 1
        ;;
    esac
  '';
in
{
  # ON-DEMAND HOSTS: off is an answer, not a failure.
  #
  # vm-03 was dropped from this check on 2026-08-19 because it reported
  # "unverifiable (unreachable)" every single night and failed the job, which
  # also held the 04:45 sync behind a red gate. The reason written down was
  # that the VM had been retired. It has not been: it is in hosts/, in the
  # flake, it resolves and it answers — it is an on-demand GPU node that is
  # DELIBERATELY off most of the time, and the same is true of the two gaming
  # guests. Removing it did not fix the noise, it only stopped checking a real
  # host, and by 2026-09-23 nobody was verifying its revision at all.
  #
  # The distinction the old loop lacked is this one. For a host that is
  # supposed to be up, silence is a failure. For a host that is supposed to be
  # down, silence is expected and the check says UNVERIFIED without going red
  # — but if it ANSWERS and it is stale, that is drift and it fails like any
  # other host. Same shape as gpu-discovery.py's UNVERIFIED, and the same rule
  # as everywhere else here: cannot check is not the same as disagrees.
  options.labo.onDemand = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      This host is expected to be powered off much of the time, so the drift
      check treats an unanswered probe as unverified rather than as a failure.
      Set on the opportunistic GPU node and the gaming guests — never on a
      machine whose silence should page someone.
    '';
  };

  config.users.groups.driftcheck = { };

  config.users.users.driftcheck = {
    isSystemUser = true;
    group = "driftcheck";
    # A real shell is required for sshd to execute the forced command; the
    # "restrict" option (no pty, no forwarding, no X11) plus command= keeps
    # this key from doing anything but the two verbs above.
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      ''command="${driftCtl}",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example hostcheck''
    ];
  };
}
