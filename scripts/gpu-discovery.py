#!/usr/bin/env python3
"""Ask the machines what cards they have, and compare against what we declare.

WHY THIS EXISTS. `labo.gpus` (modules/labo-gpus.nix) says which graphics cards
each host holds, and emit-fleet.py refuses to publish a fleet inventory that
disagrees with it. That guarantees the PUBLISHED inventory matches the
DECLARED one. It cannot guarantee either matches the metal: on 2026-09-14 a
second RTX 3050 went into gaming-01 and nobody edited anything, which is exactly
the failure no amount of cross-checking between two written files can catch.

So this asks the hosts. `drift-ctl gpus` on each machine returns what lspci
sees, over the existing locked-down driftcheck key.

THIS IS A THIRD OPINION, NOT A SOURCE, and the distinction is the whole
design. An inventory generated from live hosts reports "no cards" for every
machine that is asleep — silently, and with the authority of a measurement.
On this fleet that is not a corner case: the two gaming guests are off almost
always by design, and vm-03 is an on-demand node. So discovery never writes
anything. It only ever says "these two disagree", and a person looks.

THREE VERDICTS, NOT TWO. "Disagrees" and "could not be asked" are different
facts, and collapsing them is how a gate starts lying — the same lesson
check-answerable.py learned on the site a day earlier. A host that did not
answer is UNVERIFIED and does not fail the run; the count is reported, so a
fleet that has gone quiet shows up as a number rather than as false calm.

WHAT IS COMPARED is (slot, PCI id) — never the model name. The name is
marketing and two different cards share one ("RTX 3050" is both a GA106 2507
and a GA107 2584 on gaming-01). The id is what vfio binds by and what lspci
reads, so it is the only thing both sides can be wrong about in the same way.

Usage:
  gpu-discovery.py <nixos-iac-root>            # probe the fleet, compare
  gpu-discovery.py <nixos-iac-root> --host gpu-01 # just one
  gpu-discovery.py --selftest                  # prove the comparison first
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys

SSH_TIMEOUT_S = 12
DOMAIN = "lab.example"


def _emit_fleet(here: str):
    """Reuse emit-fleet.py's parser rather than writing a second one.

    Two readers of `labo.gpus` would be two things to keep in step, and the
    second one is always the one that rots.
    """
    path = os.path.join(here, "emit-fleet.py")
    spec = importlib.util.spec_from_file_location("emit_fleet", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ssh_gpus(host: str, key: str = None):
    """Return (cards, error). cards is a list of {'slot','id'} dicts.

    An empty list with no error is a real answer: "this machine has no NVIDIA
    display controller". Distinguishing that from "did not answer" is the
    point of returning the error separately rather than an empty list for both.
    """
    argv = ["ssh", "-4", "-n", "-o", "BatchMode=yes",
            "-o", f"ConnectTimeout={SSH_TIMEOUT_S}",
            "-o", "StrictHostKeyChecking=accept-new"]
    if key:
        argv += ["-i", key]
    argv += [f"driftcheck@{host}.{DOMAIN}", "gpus"]
    p = subprocess.run(argv, capture_output=True, text=True,
                       timeout=SSH_TIMEOUT_S * 4)
    if p.returncode != 0:
        return [], (p.stderr.strip().splitlines() or ["ssh failed"])[-1][:120]
    cards = []
    for line in p.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            cards.append(json.loads(line))
        except json.JSONDecodeError:
            return [], f"unparseable line: {line[:60]!r}"
    return cards, ""


def compare(declared: list, found: list) -> list:
    """What the two lists disagree about, as sentences. [] means they agree.

    Compared as a multiset of (slot, id): a host legitimately holds two
    identical cards, so a set would call gpu-01's pair of 2503s one card and
    never notice if one went missing.
    """
    def key(c):
        return (str(c.get("slot", "")).lower(), str(c.get("id", "")).lower())

    want = sorted(key(c) for c in declared)
    got = sorted(key(c) for c in found)
    if want == got:
        return []

    problems = []
    for missing in sorted(set(want) - set(got)):
        problems.append(f"declared at {missing[0]} ({missing[1]}) but the host does not see it")
    for extra in sorted(set(got) - set(want)):
        problems.append(f"the host has {extra[1]} at {extra[0]} and nothing declares it")
    if not problems:
        # Same slots and ids, different counts — only reachable with duplicates.
        problems.append(f"declared {len(want)} card(s), the host reports {len(got)}")
    return problems


def run(repo_root: str, only=None, key=None, prober=None) -> tuple:
    """Returns (lines, disagreements, unverified).

    `prober` is resolved at CALL time and never bound as a default argument:
    written `prober=ssh_gpus`, the default freezes the function at import and
    a test that replaces it keeps talking to the real fleet instead. That is
    not hypothetical — check-answerable.py's first test suite did exactly that
    and reported production's verdicts as its own.
    """
    prober = prober or ssh_gpus
    ef = _emit_fleet(os.path.dirname(os.path.abspath(__file__)))
    hosts_dir = os.path.join(repo_root, "hosts")
    hosts = [h for h in sorted(os.listdir(hosts_dir))
             if not h.startswith(".") and os.path.isdir(os.path.join(hosts_dir, h))]
    if only:
        hosts = [h for h in hosts if h in only]

    lines, bad, unknown = [], 0, 0
    for h in hosts:
        # A PASSTHROUGH GUEST IS NOT ASKED, and this is not a shortcut.
        # `labo.gpus` is declared on the machine the card is screwed into; a
        # guest borrowing that card sees it at an address qemu invented for
        # it. The first live run of this script found vm-03 awake and
        # reporting gaming-01's three cards at 05:00.0, 07:00.0 and 09:00.0
        # against host addresses 17:00.0, 65:00.0 and b4:00.0 — and called it
        # a divergence. Nothing had diverged; the two machines simply number
        # the same bus differently.
        #
        # Left alone, that fires every time a gaming VM is powered on, which
        # is the surest way to teach everyone to ignore this check. The card
        # is verified where it is bolted: gaming-01. Verifying it twice, once
        # through a translation layer, buys nothing and costs the alarm's
        # credibility.
        if ef._claimed_slots(hosts_dir, h):
            lines.append(f"  {'SKIPPED':11} {h}: passthrough guest, "
                         f"its cards are verified on their host")
            continue
        declared = ef._labo_gpus(hosts_dir, h)
        found, err = prober(h, key)
        if err:
            unknown += 1
            lines.append(f"  {'UNVERIFIED':11} {h}: {err}")
            continue
        problems = compare(declared, found)
        if problems:
            bad += 1
            lines.append(f"  {'DISAGREES':11} {h}: " + "; ".join(problems))
        else:
            n = len(declared)
            lines.append(f"  {'AGREES':11} {h}: {n} card(s)" if n
                         else f"  {'AGREES':11} {h}: no card, none declared")
    return lines, bad, unknown


# --------------------------------------------------------------- selftest ---
SELFTEST = [
    # (declared, found, expected number of problems)
    ([], [], 0),
    ([{"slot": "17:00.0", "id": "10de:2503"}],
     [{"slot": "17:00.0", "id": "10de:2503"}], 0),
    # a card went in and nobody declared it — the 2026-09-14 failure
    ([{"slot": "65:00.0", "id": "10de:2507"}],
     [{"slot": "65:00.0", "id": "10de:2507"},
      {"slot": "b4:00.0", "id": "10de:2584"}], 1),
    # a card was declared and pulled
    ([{"slot": "65:00.0", "id": "10de:2507"}], [], 1),
    # TRAP: two identical cards. A set comparison calls this equal.
    ([{"slot": "17:00.0", "id": "10de:2503"},
      {"slot": "65:00.0", "id": "10de:2503"}],
     [{"slot": "17:00.0", "id": "10de:2503"}], 1),
    # TRAP: right card, wrong slot — two problems, not silence
    ([{"slot": "17:00.0", "id": "10de:2503"}],
     [{"slot": "65:00.0", "id": "10de:2503"}], 2),
    # case must not matter: lspci prints B4, the repo writes b4
    ([{"slot": "b4:00.0", "id": "10de:2504"}],
     [{"slot": "B4:00.0", "id": "10DE:2504"}], 0),
]


def selftest() -> int:
    bad = 0
    for declared, found, expected in SELFTEST:
        got = len(compare(declared, found))
        if got != expected:
            bad += 1
            print(f"  MISMATCH expected {expected} problem(s), got {got}: "
                  f"{declared} vs {found}")
    print(f"selftest: {len(SELFTEST) - bad}/{len(SELFTEST)} passed")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("repo", nargs="?", help="a nixos-iac checkout")
    ap.add_argument("--host", action="append", help="probe only these")
    ap.add_argument("--key", help="ssh identity for the driftcheck user")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        return selftest()
    if not a.repo:
        ap.error("need a nixos-iac checkout (or --selftest)")

    # The comparison proves itself on every run. It is free, and a gate nobody
    # re-validates is how a saturated test survives for months.
    if selftest():
        print("gpu-discovery: SELFTEST FAILED — not trusting the verdicts")
        return 2

    lines, bad, unknown = run(a.repo, only=a.host, key=a.key)
    print("\n".join(lines))
    skipped = sum(1 for l in lines if "SKIPPED" in l)
    print(f"gpu-discovery: {len(lines) - bad - unknown - skipped} agree, "
          f"{bad} disagree, {unknown} unverified, {skipped} guests skipped")
    # Unverified never fails the run: this exists to catch a divergence, and
    # paging because a gaming VM was switched off would train everyone to
    # ignore it.
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
