# Nightly task: the sanitized fleet seed

You are running headless inside the nightly diagram job, in
`~/git/ludorl82`, with the four private IaC repos and net-cfgs checked out.
A previous session has just reconciled `net-cfgs/network-diagram.md`
against the repos, so it is the freshest description of the lab that
exists.

## Your one deliverable

Write `~/.cache/nightly-diagram-sync/fleet.json` — OUTSIDE any repo, so
nothing you do can touch a working tree. The driver gates it and decides
whether it may be published.

**Scratch space**: `.diagram-scratch/` in your working directory is yours. Write
whatever you need there to check your work, and delete it when you are
done — you have `rm` for that directory, `python3` to parse, and `ls` to
look. The driver wipes it after you either way, so nothing there survives
to influence anything.

**Validate before you finish**: parse your own output with
`python3 -c "import json; json.load(open('…/fleet.json'))"`. A malformed
file fails the whole run at the gate, which is a slow way to learn about a
trailing comma.

Beyond those two paths, change no file anywhere: your cwd holds five git
working trees, and the driver checks every one of them for changes after
you exit. Touching any of them fails the run.

**Do not verify that yourself.** The driver snapshots every tree before you
start and diffs them after you exit — running `git status` adds nothing it
does not already do, and you do not have `git` in your tool list. Measured
2026-08-19: a session spent five of its turns on `git status` across the five
repos, plus more on `find` and `echo`, ran out of budget, and never wrote the
deliverable at all — while its closing message said the file was written and
validated. Spend your turns on the seed. Your budget is finite and the write
is the only thing that matters.

It is the list of every physical thing on the network, so the public
drawings can show the boxes no IaC repo declares: the switch, the AP, the
printer, the cameras, the personal machines, the UPSes, the BMCs.

```json
{ "fleetVersion": 1, "generated": null,
  "devices": [ { "name": "gpu-01", "class": "server", "network": "vlan10",
                 "role": "agent k3s, GPU", "iacDeclared": true } ] }
```

- Source of truth: the `## Hosts` tables you just reconciled, plus anything
  else in the doc that is a physical device. Leave `generated` null — the
  driver stamps it.
- `class`: `server`, `sbc`, `vm`, `nas`, `router`, `switch`,
  `access-point`, `printer`, `camera`, `ups`, `bmc`, `desktop`, `laptop`,
  `phone`, `cloud-vm`, `domotique`.
- **`domotique` is an AGGREGATE class**, and the only one: smart plugs,
  speakers, voice satellites, the doorbell chime, the projector —
  everything that is a household appliance rather than lab gear. Emit
  **one entry per family** with a `count`, not one per device
  (`{"name":"prises-intelligentes","class":"domotique","count":6, …}`).
  The drawing should say that surface exists without turning the living
  room into a dozen labelled boxes.
- **The energy gateway is the exception, and it gets named**: call it
  `hilo`, `model` « router Hilo », and say in its `role` that it is
  the gateway for **Hilo, the Hydro-Québec demand-response program** —
  the utility pays participants to shave peak load, and it reaches into
  the house through this box. That is genuinely interesting to a Québécois
  readership and it is a published consumer program, not a private detail.
- `network`: `vlan10`, `vlan50`, `wireguard`, `cloud-01`, or `out-of-band` —
  the last one meaning "not reachable on the normal network", which covers
  BMCs and gear like the UPSes that sit on no network at all.
- `role`: a short French phrase, no names.
- `location`: where the box physically is — `wall-rack`, `rolling-rack`,
  `not-racked` (voice satellites, personal machines, anything loose in the
  house) or `off-site`. From `physical-layout.md`, which a sibling session
  reconciles nightly.
- `rackOrder`: for racked gear only, an integer counting from the TOP of
  that rack (1 = topmost), following the order the document lists them in.
  It is a stacking order, not a U position — the document does not record
  U positions, so do not invent any.
- `power`: the name of the UPS entry that feeds it (`ups-01`, `ups-02`,
  `ups-03`), or omit when the document does not say. This is what makes the
  survivor-island story visible, so get it right or leave it out.
- `model`: the actual hardware, vendor and model as the document records
  it — « CyberPower OR700LCDRM1U », « Raspberry Pi 5 », « Netgear GS348 ».
  This is deliberate: the drawing names the real gear. Omit it when the
  document does not say. **Never a serial number**, and never firmware or
  software versions — the model is the interesting part, the patch level is
  nobody's business.
  Every device may be named, the firewall and the NAS included: their
  hardware is already visible in the published rack photographs, so
  withholding it from a drawing costs accuracy and buys nothing. What
  protects those two is that nothing is port-forwarded — not obscurity.
- `spec`: a SHORT capability line that complements the model rather than
  repeating it — « 700 VA, 1U », « 48 ports, sans ventilateur », « aarch64,
  8 Go », « bi-bande, PoE ». Omit when the model already says everything.
- `hostedBy`: for a VM or a BMC, the `name` of the machine it lives in or
  belongs to. A VM is *inside* a host, not beside it, and the drawing nests
  them on that field. Omit for everything else.

- `iacDeclared`: true when the device is one of the hosts the four IaC
  repos declare.

Alongside `devices`, emit a `racks` map describing the enclosures
themselves — again generically:

```json
"racks": { "wall-rack":    { "units": 8,  "kind": "mural, 2 montants" },
           "rolling-rack": { "units": 42, "kind": "sur roulettes" } }
```

`units` is the rack's total height in U, which the document DOES record.
It is the frame's height, not a position: you still must not invent a U
position for any device.

**Sanitizing is the whole job here.** Use the SAME map the sanitizers use —
read `nixos-iac/scripts/sanitize-public.sh` for it (gpu-01 → gpu-01,
pi-02 → pi-02, and so on). For devices the map does not cover, invent a
generic name from the class with a counter (`cam-01`, `printer-01`,
`switch-01`, `ap-01`, `laptop-01`) and keep it stable run to run.

**No addresses. None.** Not IPv4, not IPv6, not MACs, not subnets, not
`.x` prose forms — the drawing does not need them, and leaving them out
removes the whole category. No real hostnames, no real domains, no serial
numbers, no SSIDs, no personal names.

The driver runs two gates over this file — a positive allowlist and a
denylist of real names — and refuses to publish on either. Do not treat
those gates as the design: write it clean.

## Why the shape is what it is

The public architecture drawing can only show the boxes the IaC repos
declare — about half the lab. This file is how the switch, the AP, the
printer, the cameras, the personal machines, the UPSes and the BMCs reach
it. Completeness is the value; getting there safely is the constraint.

Report at the end: how many devices, how many of them `iacDeclared`, and
anything in the doc you could not classify confidently.
