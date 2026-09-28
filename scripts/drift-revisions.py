#!/usr/bin/env python3
"""Does every host run the configuration cp-1 says it should?

This is the revision half of the Cronicle event "nixos-iac Drift Check". It
used to be a `for` loop pasted into that event, which is why it was wrong in
two ways nobody could see in a diff:

  * IT DID NOT KNOW ABOUT THE CANARY BRANCH. vm-01 and vm-02 carry
    `labo.canary = true`, so comin deploys them the `canary` branch as its
    testing branch and they are SUPPOSED to be ahead of cp-1 from the Sunday
    flake.lock bump until the judge promotes it. The loop compared every host
    to cp-1, so the check went red by design once a week -- and, once the
    promotion livelocked in September 2026, every single day for three days
    while labodeludo.dev/architecture told the public the diagram had drifted.
    A red that fires on correct behaviour is how a check stops being read.

  * IT HAD STOPPED LOOKING AT vm-03, console-vm, gaming-01 AND THE ARCADES.
    vm-03 was removed on 2026-08-19 with "the VM is retired" written beside
    it; that was never true again after it was rebuilt, and by 2026-09-23 its
    revision was verified by nobody. The others were simply never added. The
    host list now comes from hosts/, so a machine cannot be forgotten by
    omission -- adding a host to the flake adds it here.

The verdicts:

    ok           the host runs what it is supposed to run
    STALE        it answered, and with the wrong revision  -> FAILS
    unverifiable an always-on host did not answer          -> FAILS
    off          an on-demand host did not answer          -> fine

`prober` is injected rather than defaulted at import for the reason spelled
out in gpu-discovery.py: a test that replaces a frozen default keeps talking
to the real fleet and reports production's verdicts as its own.
"""
import os
import re
import subprocess
import sys

CANARY_RE = re.compile(r"^\s*labo\.canary\s*=\s*true\s*;", re.M)
ONDEMAND_RE = re.compile(r"^\s*labo\.onDemand\s*=\s*true\s*;", re.M)


def _flag(hosts_dir, host, rx):
    cfg = os.path.join(hosts_dir, host, "configuration.nix")
    if not os.path.isfile(cfg):
        return False
    with open(cfg, encoding="utf-8") as fh:
        return bool(rx.search(fh.read()))


def fleet(repo_root):
    """Every host the flake declares, as hosts/ spells them."""
    hosts_dir = os.path.join(repo_root, "hosts")
    return sorted(h for h in os.listdir(hosts_dir)
                  if not h.startswith(".")
                  and os.path.isdir(os.path.join(hosts_dir, h)))


def ssh_revision(host, key):
    """Ask a host what git revision built it. ('', reason) when it will not say."""
    try:
        p = subprocess.run(
            ["ssh", "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
             "-o", "StrictHostKeyChecking=accept-new",
             "-o", "UserKnownHostsFile=/tmp/nd_kh2",
             f"driftcheck@{host}.lab.example", "true"],
            capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return "", "timed out"
    rev = p.stdout.strip()
    if not rev:
        return "", "unreachable or no configurationRevision yet"
    return rev, ""


def check(repo_root, cp-1, canary=None, key=None, prober=None, only=None):
    """Compare every host's running revision to what it should be running.

    Returns (lines, failures). `canary` is the tip of the canary branch, or
    None when no canary is in flight; it is accepted ONLY on hosts that
    declare labo.canary, and only while it differs from cp-1.
    """
    prober = prober or ssh_revision
    hosts_dir = os.path.join(repo_root, "hosts")
    hosts = fleet(repo_root)
    if only:
        hosts = [h for h in hosts if h in only]

    lines, failures = [], []
    for h in hosts:
        is_canary = _flag(hosts_dir, h, CANARY_RE)
        on_demand = _flag(hosts_dir, h, ONDEMAND_RE)

        # A canary is allowed to be on either: comin switches it to the
        # testing branch within minutes of a push and back again when the
        # branch is reset, and both of those are the system working.
        allowed = {cp-1}
        if is_canary and canary and canary != cp-1:
            allowed.add(canary)

        rev, err = prober(h, key)
        if not rev:
            if on_demand:
                lines.append(f"{h}: off ({err}) — on-demand, not a failure")
            else:
                lines.append(f"{h}: unverifiable ({err})")
                failures.append(f"{h}=unverifiable")
            continue
        if rev in allowed:
            which = "canary" if rev != cp-1 else cp-1[:7]
            lines.append(f"{h}: ok ({which})")
        else:
            lines.append(f"{h}: STALE at {rev[:7]}")
            failures.append(f"{h}={rev[:7]}")
    return lines, failures


def main(argv):
    if len(argv) < 3:
        print("usage: drift-revisions.py <repo_root> <master_rev> [canary_rev] "
              "[--key PATH]", file=sys.stderr)
        return 2
    repo_root, cp-1 = argv[1], argv[2]
    rest = argv[3:]
    key = None
    if "--key" in rest:
        i = rest.index("--key")
        key = rest[i + 1]
        rest = rest[:i] + rest[i + 2:]
    canary = rest[0] if rest and rest[0] not in ("", "-") else None

    lines, failures = check(repo_root, cp-1, canary, key)
    for l in lines:
        print(l)
    if failures:
        print("drift-revisions: " + " ".join(failures))
        return 1
    print(f"drift-revisions: {len(lines)} hosts at {cp-1[:7]}"
          + (f" (canary {canary[:7]})" if canary and canary != cp-1 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
