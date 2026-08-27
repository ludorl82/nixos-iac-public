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
        problems += check_racked(
            devices,
            os.path.join(os.path.dirname(os.path.abspath(src_path)),
                         "physical-layout.md"))

    if problems:
        print("emit-fleet: REFUSING to emit — " + "; ".join(problems), file=sys.stderr)
        return 1

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
