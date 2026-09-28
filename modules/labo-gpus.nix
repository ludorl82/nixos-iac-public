# Which graphics cards a host physically holds — as a field, not as prose.
#
# WHY (2026-09-16). A second RTX 3050 went into gaming-01 on 2026-09-14 and the
# fleet drawing never noticed. Nothing was broken: `fleet.json` describes GPUs
# in a free-text `spec` string, and no gate reads free text. `emit-fleet.py`
# already reconciles device NAMES and a `gpu: true|false` boolean, and its own
# docstring explains why that boolean exists — the same claim used to live in
# `role`, drifted for 19 days, and was moved out of the prose into a field.
# This applies that lesson one level down: WHICH card is still prose, and it
# drifted exactly as `role` did.
#
# How bad the prose is, measured rather than asserted: on 2026-09-16
# hosts/gpu-01/configuration.nix said "2x RTX 3060" on line 1, "the 2x RTX 3060"
# on line 5, "3x RTX 3060 (GA106) since 2026-09-11" on line 205 and "the two
# 3060s" on line 270. One file, two answers. Reading the live host settled it
# at three — and showed the comments were wrong about the parts too: two are
# 10de:2503 and the third is a 10de:2504 Lite Hash Rate.
#
# EVERY VALUE HERE WAS READ OFF THE LIVE HOST with `lspci -nn -d 10de:`, never
# copied from a comment. hosts/gaming-01/configuration.nix earned that rule the
# hard way: an early comment there guessed 2504 for a 3060 that was really
# 2503 — and gpu-01 turns out to have both parts, so the guess would have looked
# plausible forever.
#
# TWO CONSUMERS, SO IT CANNOT BECOME DECORATION. A declaration nothing reads
# is prose in a different font, and would drift the same way:
#
#   1. the assertion below, at Nix eval time. A card marked `passthrough` must
#      have its ids in this host's `boot.kernelParams`. CI evaluates every host
#      on every PR, and comin refuses a configuration that does not evaluate,
#      so the two lists cannot disagree for longer than it takes to notice.
#   2. `scripts/emit-fleet.py`, which joins this against `net-cfgs/fleet.json`
#      and RENDERS the `spec` string from it instead of trusting the prose
#      already there — so the published inventory cannot be stale while this
#      is current.
#
# It ASSERTS rather than GENERATES `vfio-pci.ids` on purpose. Generating it
# would make an inventory edit rewrite the kernel command line of the host
# that runs both gaming guests and the cluster's GPU node, for no behavioural
# gain — the set would be identical. Asserting gives the same protection and
# changes nothing that boots.
{ config, lib, ... }:

let
  card = lib.types.submodule {
    options = {
      slot = lib.mkOption {
        type = lib.types.str;
        example = "65:00.0";
        description = ''
          PCI address as `lspci` prints it, without the domain. This is the
          join key: a guest's libvirt-domain.xml claims a bus/slot/function,
          and that is how emit-fleet.py works out which card each VM gets
          without anyone restating it.
        '';
      };
      id = lib.mkOption {
        type = lib.types.str;
        example = "10de:2507";
        description = "PCI vendor:device of the card itself.";
      };
      audioId = lib.mkOption {
        type = lib.types.str;
        example = "10de:228e";
        description = ''
          PCI vendor:device of the card's HDMI audio function. Needed because
          vfio binds by id and the audio function sits in the same IOMMU
          group — leaving it out is how a card ends up half-bound.
        '';
      };
      model = lib.mkOption {
        type = lib.types.str;
        example = "RTX 3050";
        description = ''
          Marketing name, as it should read in the published inventory. Two
          physically different cards may share one name, which is why `id`
          and not this is what identifies a card.
        '';
      };
      die = lib.mkOption {
        type = lib.types.str;
        example = "GA106";
        description = "Silicon, e.g. GA106. Distinguishes same-name parts.";
      };
      vram = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "12 Go";
        description = ''
          Card memory, as `nvidia-smi` reports it. OPTIONAL, and empty means
          "not read", never "none" — a card bound to vfio is invisible to the
          host it sits in, so gaming-01's three can only be read from the guest
          that borrows them, and only while that guest is running.
        '';
      };
      passthrough = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Bound to vfio-pci for a guest rather than driven by this host. When
          true, the assertion below requires both ids in boot.kernelParams.
        '';
      };
    };
  };

  bound = builtins.filter (g: g.passthrough) config.labo.gpus;
  params = builtins.concatStringsSep " " config.boot.kernelParams;
in
{
  options.labo.gpus = lib.mkOption {
    type = lib.types.listOf card;
    default = [ ];
    description = ''
      The graphics cards this host physically holds. Declared on the machine
      the card is SCREWED INTO, never on the guest that borrows it — a card
      passed to a VM is still the host's hardware, and restating it on both
      sides is a second place to drift.
    '';
  };

  config.assertions = lib.concatMap
    (g: [
      {
        assertion = lib.hasInfix g.id params;
        message = ''
          labo.gpus: ${g.model} at ${g.slot} is marked passthrough but its id
          ${g.id} is not in boot.kernelParams. vfio binds by id, so the card
          would stay with the host and every guest that claims it would fail
          to start.
        '';
      }
      {
        assertion = lib.hasInfix g.audioId params;
        message = ''
          labo.gpus: ${g.model} at ${g.slot} is marked passthrough but its
          audio function ${g.audioId} is not in boot.kernelParams. The audio
          function shares the card's IOMMU group; binding one without the
          other leaves the group split and the passthrough refused.
        '';
      }
    ])
    bound;
}
