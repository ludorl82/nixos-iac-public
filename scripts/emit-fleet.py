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
import sys

REQUIRED = ("name", "class", "network", "role", "iacDeclared")
# Mirrors the classes the drawing knows how to render; an unknown one would be
# drawn into no band at all, silently, which is the failure this catches.
CLASSES = {
    "server", "sbc", "vm", "nas", "router", "switch", "access-point", "printer",
    "camera", "ups", "bmc", "desktop", "laptop", "phone", "cloud-vm", "domotique",
}
NETWORKS = {"vlan10", "vlan50", "wireguard", "cloud-01", "out-of-band"}


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    src_path, dest_path = sys.argv[1], sys.argv[2]

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
