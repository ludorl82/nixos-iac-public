#!/usr/bin/env python3
"""Emit the fleet seed from its durable source. Replaces an LLM session.

Until 2026-08-19 this file was regenerated every night by a headless Claude
session reading `net-cfgs/physical-layout.md` — prose in, JSON out. The driver's
own comment called it "a structured transform, two gates after", which is the
category that needs no judgement, and it earned that description the hard way:
in one day it failed four distinct ways (starved of turns by its own tool
allowlist, a missing deliverable treated as a note rather than a failure, its
publication gated behind unrelated snapshots, and a sandbox question no headless
run can answer). It had not shipped since 2026-08-11 while the job reported
green.

The data is now durable state in `net-cfgs/fleet.json`. This script only
validates and copies.

NOTHING RECONCILES THAT FILE YET, and you should know it. An earlier version of
this docstring claimed session C did — session C read the claim, checked its own
prompt, and said plainly that it has exactly one deliverable
(`physical-layout.md`), that its rules forbid touching any other file, and that
the driver commits only that file by name. It was right. The maintainer asserted
here did not exist.

So `fleet.json` is human-maintained today, and it can go stale silently — the
same failure this change was meant to end, in a new place. Two ways to close it,
both open: give the nightly a session whose one deliverable IS `fleet.json`, or
cross-check the *declared* half deterministically — `nixos-iac/hosts/*` mapped
through `scripts/host-map.env` should equal the `iacDeclared: true` device
names, and a mismatch should refuse the emit. The undeclared half (switches,
UPSes, the printer) has no source of truth and genuinely needs a human.
Recorded in net-cfgs/backlog.md. Standard library only, deliberately: PyYAML is present on the console
but declared nowhere, and swapping LLM flakiness for an undeclared dependency
would be no bargain.

Usage: emit-fleet.py <source.json> <dest.json>
Exits non-zero, loudly, on anything it cannot vouch for.
"""
import json
import os
import re
import sys

REQUIRED = ("name", "class", "network", "role", "iacDeclared")
# Mirrors the classes the drawing knows how to render; an unknown one would be
# drawn into no band at all, silently, which is the failure this catches.
CLASSES = {
    "server", "sbc", "vm", "nas", "router", "switch", "access-point", "printer",
    "camera", "ups", "bmc", "desktop", "laptop", "phone", "cloud-vm", "domotique",
}
NETWORKS = {"vlan10", "vlan50", "wireguard", "cloud-01", "out-of-band"}


def _aliases(map_path: str) -> dict:
    """Real hostname -> public alias, from the shared host map.

    Parses the bash file rather than importing it: HOST_MAP is the sanitizers'
    sed list, FLEET_ALIAS_EXTRA covers the hosts that deliberately bypass that
    list (cloud-01 is special-cased there; arcade1/2 are never renamed).
    """
    out = {}
    for line in open(map_path):
        if line.lstrip().startswith("#"):
            continue
        for real, alias in re.findall(r'"([^":]+):([^"]+)"', line):
            out[real] = alias
    return out


def check_declared(devices, repo_root: str) -> list:
    """The declared half is machine-checkable; the rest genuinely is not.

    Every directory in nixos-iac/hosts/ is a host this lab declares. Mapped
    through the shared alias table, that set must equal the devices fleet.json
    marks `iacDeclared: true`. When they disagree, fleet.json has drifted from
    the IaC — a host was added or retired and the drawing was not told.

    This exists because nothing else reconciles fleet.json. The nightly's
    session C was once claimed to, in this very file; C read the claim and
    correctly refuted it (one deliverable, may not touch another file). The
    The UNDECLARED half splits again: the racked networking/power gear IS
    sourced, by net-cfgs/physical-layout.md — see check_racked, which covers it.
    Only the household devices and the BMC board models have no source at all.
    """
    hosts_dir = os.path.join(repo_root, "hosts")
    map_path = os.path.join(repo_root, "scripts", "host-map.env")
    if not os.path.isdir(hosts_dir) or not os.path.isfile(map_path):
        return [f"cannot cross-check: missing {hosts_dir} or {map_path}"]
    alias = _aliases(map_path)
    # skip dotfiles: an editor backup or a stray .something is not a host
    declared_hosts = sorted(d for d in os.listdir(hosts_dir)
                            if not d.startswith(".")
                            and os.path.isdir(os.path.join(hosts_dir, d)))
    expected = {alias.get(h, h) for h in declared_hosts}
    actual = {d["name"] for d in devices if d.get("iacDeclared")}
    problems = []
    for missing in sorted(expected - actual):
        problems.append(f"declared in nixos-iac/hosts/ but not iacDeclared in fleet.json: {missing}")
    for extra in sorted(actual - expected):
        problems.append(f"iacDeclared in fleet.json but no nixos-iac/hosts/ entry: {extra}")
    return problems


# Classes whose device models physical-layout.md actually names. The doc
# describes servers and the NAS by hostname and role instead ("nas —
# QNAP NAS", "gaming-01 (NixOS)"), carrying no model string to compare, so they
# are out of scope here rather than exempted for convenience.
RACKED_CLASSES = {"switch", "access-point", "ups", "router", "sbc"}


def check_racked(devices, doc_path: str) -> list:
    """Cross-check the half of fleet.json that physical-layout.md also documents.

    Before fleet.json existed, it was regenerated from that prose every night,
    so the doc was the single source and the two could not disagree. Now both
    are hand-maintained and describe the same switches, AP, router, Pis and
    UPSes independently — this check is what replaces the derivation.

    One-directional on purpose: every model fleet.json claims must appear in the
    prose, but the reverse cannot be read reliably out of 139 lines of French
    narrative. So this catches a device swapped in fleet.json and forgotten in
    the doc, not the opposite.
    """
    try:
        doc = open(doc_path).read().lower()
    except OSError as e:
        return [f"cannot cross-check physical-layout.md: {e}"]
    problems = []
    for d in devices:
        if d.get("class") not in RACKED_CLASSES:
            continue
        model = d.get("model")
        if not model:
            continue
        # the longest run in the model string is its distinctive part:
        # "Netgear GS348" -> GS348, "CyberPower OR700LCDRM1U" -> OR700LCDRM1U
        token = max(re.findall(r"[A-Za-z0-9\-/]{4,}", model), key=len, default="")
        if token and token.lower() not in doc:
            problems.append(
                f"{d['name']}: model {model!r} is not named in physical-layout.md "
                f"(looked for {token!r}) — the two inventories have diverged")
    return problems


# `gpu = true;` / `gpu = false;` — a let-binding, not a module option, so it is
# matched textually. arcade2 is the only host carrying one today.
GPU_BINDING = re.compile(r"^\s*gpu\s*=\s*(true|false)\s*;", re.M)
# A PCI device handed to a guest. On this fleet that is always a graphics card
# and its audio function — the only reason anything here is vfio-bound.
PCI_HOSTDEV = re.compile(r"<hostdev[^>]*type=['\"]pci['\"]")

# --- labo.gpus: which cards, not just whether -------------------------------
#
# `gpu: true|false` above answers "does this thing have a card". It cannot
# answer "which", and on 2026-09-14 a second RTX 3050 went into gaming-01 without
# anything noticing: the model lived in fleet.json's free-text `spec`, and no
# gate reads free text. So the model moves into a field on both sides —
# `labo.gpus` in nixos-iac (modules/labo-gpus.nix), `gpus` in fleet.json — and
# `spec` stops being believed and starts being RENDERED from it.
#
# Parsed with a regex rather than evaluated: this script is standard-library
# only and runs on the console, where nix is not installed. The format is one
# card per `{ ... }`, so the block scan below is order-independent within a
# card — a positional regex would break the first time somebody swaps two
# attributes.
LABO_GPUS_BLOCK = re.compile(r"labo\.gpus\s*=\s*\[(.*?)\];", re.S)
LABO_GPUS_CARD = re.compile(r"\{([^{}]*)\}")
LABO_GPUS_ATTR = re.compile(r"(\w+)\s*=\s*(?:\"([^\"]*)\"|(true|false))\s*;")
# libvirt writes PCI addresses in hex with an 0x prefix and a separate domain;
# lspci (and therefore labo.gpus) writes bus:slot.function. Joining them needs
# one of the two normalised, and the XML is the one with a machine format.
XML_HOSTDEV_ADDR = re.compile(
    r"<address\s+domain='[^']*'\s+bus='0x([0-9a-fA-F]+)'\s+"
    r"slot='0x([0-9a-fA-F]+)'\s+function='0x([0-9a-fA-F]+)'")


def _labo_gpus(hosts_dir: str, host: str) -> list:
    """The cards a host DECLARES it physically holds. [] when it declares none.

    Returns dicts with at least slot/id/model/die, plus vram when it was read.
    A host with no `labo.gpus` block returns [] — which is a claim, not a
    silence, because modules/labo-gpus.nix gives every host the option.
    """
    cfg = os.path.join(hosts_dir, host, "configuration.nix")
    if not os.path.isfile(cfg):
        return []
    with open(cfg, encoding="utf-8") as fh:
        m = LABO_GPUS_BLOCK.search(fh.read())
    if not m:
        return []
    cards = []
    for card in LABO_GPUS_CARD.finditer(m.group(1)):
        attrs = {}
        for k, sval, bval in LABO_GPUS_ATTR.findall(card.group(1)):
            attrs[k] = sval if bval == "" else (bval == "true")
        if attrs:
            cards.append(attrs)
    return cards


def _claimed_slots(hosts_dir: str, host: str) -> set:
    """PCI slots this host's libvirt domain claims, as `bus:slot.function`.

    Only function 0 matters: every card here is passed through with its audio
    function beside it, and counting both would double every card.
    """
    dom = os.path.join(hosts_dir, host, "libvirt-domain.xml")
    if not os.path.isfile(dom):
        return set()
    with open(dom, encoding="utf-8") as fh:
        xml = re.sub(r"<!--.*?-->", "", fh.read(), flags=re.S)
    out = set()
    for bus, slot, fn in XML_HOSTDEV_ADDR.findall(xml):
        if int(fn, 16) == 0:
            out.add(f"{bus.lower():0>2}:{slot.lower():0>2}.{int(fn, 16)}")
    return out


def _expected_gpus(hosts_dir: str, devices: list, alias: dict) -> dict:
    """host -> the cards it should be credited with, in the inventory.

    Declared on the machine the card is screwed into; a guest is credited with
    whatever its libvirt domain claims. That join is why nobody restates a card
    on both sides — restating it is a second place to drift.

    SCOPED BY `hostedBy`, and it has to be. PCI addresses are per-machine, not
    fleet-wide: gaming-01 and gpu-01 both have a card at 65:00.0, so a join on slot
    alone credited arcade1 with one of gpu-01's 3060s. The first real run of this
    function did exactly that. `hostedBy` is the right key because it is an
    independent fact — main() already refuses a device whose hostedBy names
    nothing, and swapping a graphics card never changes which box a VM runs on.

    A card lent to a guest stays listed on its host too, deliberately: it is
    still that machine's hardware, and the rack drawing describes hardware.
    """
    hosts = [h for h in sorted(os.listdir(hosts_dir))
             if not h.startswith(".") and os.path.isdir(os.path.join(hosts_dir, h))]
    by_host = {h: list(_labo_gpus(hosts_dir, h)) for h in hosts}

    # public alias -> real host dir, to read hostedBy (written in public names)
    unalias = {alias.get(h, h): h for h in hosts}
    hosted_by = {d.get("name"): d.get("hostedBy") for d in devices if d.get("name")}

    for guest in hosts:
        claimed = _claimed_slots(hosts_dir, guest)
        if not claimed:
            continue
        parent_public = hosted_by.get(alias.get(guest, guest))
        parent = unalias.get(parent_public)
        if parent is None:
            by_host[guest] = []
            continue
        by_host[guest] = [c for c in by_host.get(parent, [])
                          if c.get("slot") in claimed]
    return by_host


def _card_key(c: dict) -> tuple:
    """What makes two cards the same card, for grouping and for comparison.

    `slot` is deliberately NOT in here. It identifies a card on one machine,
    but the inventory describes what a device HAS, and moving a card between
    two slots of the same box is not an inventory change. `passthrough` IS in
    here: which cards the host keeps is a fact about the machine, and it has
    changed twice on gaming-01 already.
    """
    return (c.get("model", "?"), c.get("die", ""), c.get("vram", ""),
            bool(c.get("passthrough", False)))


def render_spec(cards: list) -> str:
    """The `spec` string for a device, from its cards. Stable and boring.

    Grouped by (model, die, vram) so three identical cards read "3x RTX 3060"
    rather than as a list, which is how a human writes it and how the rack
    drawing has always shown it. Order is the declaration order, so the string
    only changes when the hardware does.
    """
    groups = []
    for c in cards:
        key = _card_key(c)
        for g in groups:
            if g[0] == key:
                g[1] += 1
                break
        else:
            groups.append([key, 1])
    parts = []
    for (model, die, vram, vfio), n in groups:
        # "vfio" rides in the detail rather than as a trailing clause on the
        # whole string. The old prose said "GTX 960 + RTX 3050 en
        # vfio-passthrough", which reads well right up to the day one card of
        # three is not passed through — and then it is quietly wrong about two
        # of them. Per-card, there is no such day.
        detail = ", ".join(x for x in (die, vram, "vfio" if vfio else "") if x)
        head = f"{n}x {model}" if n > 1 else model
        parts.append(f"{head} ({detail})" if detail else head)
    return " + ".join(parts)


def check_gpu_models(devices, repo_root: str) -> list:
    """Cross-check WHICH cards, not just whether there is one.

    Exact on a multiset of (model, die, vram), never on prose: `spec` is the
    thing that drifted, so matching against it would be checking the suspect's
    alibi with the suspect. Devices the IaC says have no cards are skipped
    rather than required to say so — check_gpu already owns the boolean, and
    two gates asserting the same fact is one gate too many.
    """
    hosts_dir = os.path.join(repo_root, "hosts")
    map_path = os.path.join(repo_root, "scripts", "host-map.env")
    if not os.path.isdir(hosts_dir) or not os.path.isfile(map_path):
        return [f"cannot cross-check GPU models: missing {hosts_dir} or {map_path}"]
    alias = _aliases(map_path)
    by_name = {d["name"]: d for d in devices if d.get("name")}
    problems = []
    for host, cards in _expected_gpus(hosts_dir, devices, alias).items():
        if not cards:
            continue
        d = by_name.get(alias.get(host, host))
        if d is None:
            continue  # check_declared already reports the missing device
        want = sorted(_card_key(c) for c in cards)
        got = sorted(_card_key(g) for g in d.get("gpus", []))
        if "gpus" not in d:
            problems.append(
                f"{d['name']}: nixos-iac declares {len(cards)} card(s) "
                f"({render_spec(cards)}) but fleet.json has no \"gpus\" field")
        elif want != got:
            problems.append(
                f"{d['name']}: nixos-iac declares {render_spec(cards)} but "
                f"fleet.json says {render_spec(d['gpus']) or '(nothing)'} "
                f"— the two inventories have diverged")
    return problems



def _iac_gpu(hosts_dir: str, host: str):
    """Does the IaC say this host has a graphics card? True, False, or None.

    Two signals, in order of authority:

    1. A `gpu = true|false;` binding in configuration.nix. It is named `gpu`
       and it gates the nvidia driver, so it answers exactly what is asked.
    2. Otherwise, a PCI `<hostdev>` in libvirt-domain.xml. That is a proxy, and
       worth naming as one: it proves a PCI device is passed through, not that
       the device is a GPU. It holds here because passthrough on this fleet
       exists for exactly one reason. Should that stop being true, the check
       fails in the safe direction — it complains, and a person looks.

    None means the IaC has no opinion, and a check with no source says nothing
    rather than guessing.
    """
    cfg = os.path.join(hosts_dir, host, "configuration.nix")
    if os.path.isfile(cfg):
        with open(cfg, encoding="utf-8") as fh:
            m = GPU_BINDING.search(fh.read())
        if m:
            return m.group(1) == "true"
    dom = os.path.join(hosts_dir, host, "libvirt-domain.xml")
    if os.path.isfile(dom):
        with open(dom, encoding="utf-8") as fh:
            return bool(PCI_HOSTDEV.search(fh.read()))
    return None


def check_gpu(devices, repo_root: str) -> list:
    """Cross-check the GPU claim, because this prose already drifted once.

    On 2026-09-07 fleet.json still described arcade2 as "GPU en attente
    d'installation" while hosts/arcade2/configuration.nix had carried
    `gpu = true` since 2026-08-22. Nothing caught it: check_declared compares
    sets of NAMES and passed, check_racked skips VMs entirely, and the claim
    lived in `role` — free prose no gate can read. It surfaced only because a
    nightly session happened to mention it in a report.

    So the fact moves out of the prose and into a field: `gpu: true|false`,
    checked against the repo. Where the IaC has an opinion the field is
    REQUIRED — a silent omission is how the first divergence lasted 19 days.
    Where it has none, the field is optional and unchecked.
    """
    hosts_dir = os.path.join(repo_root, "hosts")
    map_path = os.path.join(repo_root, "scripts", "host-map.env")
    if not os.path.isdir(hosts_dir) or not os.path.isfile(map_path):
        return [f"cannot cross-check GPUs: missing {hosts_dir} or {map_path}"]
    alias = _aliases(map_path)
    by_name = {d["name"]: d for d in devices if d.get("name")}
    problems = []
    for host in sorted(os.listdir(hosts_dir)):
        if host.startswith(".") or not os.path.isdir(os.path.join(hosts_dir, host)):
            continue
        want = _iac_gpu(hosts_dir, host)
        if want is None:
            continue
        d = by_name.get(alias.get(host, host))
        if d is None:
            continue  # check_declared already reports the missing device
        if "gpu" not in d:
            problems.append(
                f"{d['name']}: nixos-iac says gpu={str(want).lower()} but fleet.json "
                f'does not say either way — add "gpu": {str(want).lower()}')
        elif bool(d["gpu"]) is not want:
            problems.append(
                f"{d['name']}: fleet.json says gpu={str(bool(d['gpu'])).lower()}, "
                f"nixos-iac says {str(want).lower()} — the two inventories have diverged")
    return problems


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("usage: emit-fleet.py <source.json> <dest.json> [nixos-iac-root]", file=sys.stderr)
        return 2
    src_path, dest_path = sys.argv[1], sys.argv[2]
    repo_root = sys.argv[3] if len(sys.argv) == 4 else None

    try:
        with open(src_path) as f:
            src = json.load(f)
    except FileNotFoundError:
        print(f"emit-fleet: source missing: {src_path}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"emit-fleet: source is not valid JSON: {e}", file=sys.stderr)
        return 1

    devices = src.get("devices")
    if not isinstance(devices, list) or not devices:
        print("emit-fleet: source has no devices", file=sys.stderr)
        return 1

    problems, names = [], set()
    for i, d in enumerate(devices):
        who = d.get("name", f"#{i}")
        for k in REQUIRED:
            if k not in d:
                problems.append(f"{who}: missing {k}")
        if d.get("class") not in CLASSES and "class" in d:
            problems.append(f"{who}: unknown class {d['class']!r}")
        if d.get("network") not in NETWORKS and "network" in d:
            problems.append(f"{who}: unknown network {d['network']!r}")
        if who in names:
            problems.append(f"{who}: duplicate name")
        names.add(who)

    # hostedBy must point at something that exists, or the drawing nests a VM
    # under a machine it cannot find and drops it
    for d in devices:
        h = d.get("hostedBy")
        if h and h not in names:
            problems.append(f"{d.get('name')}: hostedBy {h!r} is not a device here")

    if repo_root:
        problems += check_declared(devices, repo_root)
        problems += check_gpu(devices, repo_root)
        problems += check_gpu_models(devices, repo_root)
        problems += check_racked(
            devices,
            os.path.join(os.path.dirname(os.path.abspath(src_path)),
                         "physical-layout.md"))

    if problems:
        print("emit-fleet: REFUSING to emit — " + "; ".join(problems), file=sys.stderr)
        return 1

    # `spec` is RENDERED for anything carrying cards, never copied. That string
    # is what drifted — it said "GTX 960 + RTX 3050" for two days after a
    # second 3050 went in — and the only durable fix for prose that can go
    # stale is to stop writing it by hand. Devices with no cards keep whatever
    # `spec` they have: "48 ports, sans ventilateur" has no other source.
    for d in devices:
        if d.get("gpus"):
            d["spec"] = render_spec(d["gpus"])

    out = {
        "fleetVersion": src.get("fleetVersion", 1),
        # the driver stamps this; null here on purpose, same as the old session
        "generated": None,
        "devices": devices,
    }
    if "racks" in src:
        out["racks"] = src["racks"]

    with open(dest_path, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"emit-fleet: {len(devices)} devices -> {dest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
