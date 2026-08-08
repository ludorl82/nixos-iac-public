#!/usr/bin/env python3
"""Emit topology.json for the public snapshot (hardware layer).

Runs against the ALREADY-SANITIZED tree (sanitize-public.sh calls this after
every substitution, before the verification gate), so everything it can
possibly read is already fictional — and the gate re-scans its output like
any other file in the snapshot.

Extraction is structural parsing, not Nix evaluation: the fields the
architecture view needs (host list, arch, k3s role, networks, modules) are
all present as literal attributes. Fail-closed: zero hosts, or a host dir
the flake does not reference, kills the run rather than emitting a partial
layer.

Contract: labodeludo.dev scripts/topology/README.md (topologyVersion 1).
"""
import json
import os
import re
import sys

def die(msg):
    print(f"emit-topology: {msg}", file=sys.stderr)
    sys.exit(1)

if len(sys.argv) != 2:
    die("usage: emit-topology.py <sanitized-tree>")
ROOT = sys.argv[1]

flake_path = os.path.join(ROOT, "flake.nix")
if not os.path.isfile(flake_path):
    die(f"no flake.nix under {ROOT}")
flake = open(flake_path, encoding="utf-8").read()

# nixosConfigurations.<name> = ... { system = "arch"; ... } — the system
# attribute is always the first line of the block, so pairing the name with
# the next `system =` after it is reliable here.
hosts = {}
for m in re.finditer(r'nixosConfigurations\.([\w-]+)\s*=', flake):
    name = m.group(1)
    tail = flake[m.end():m.end() + 500]
    arch = re.search(r'system\s*=\s*"([^"]+)"', tail)
    if arch:
        arch = arch.group(1)
    elif "nixos-raspberrypi" in tail:
        # nixosInstaller blocks carry no system attribute; the Pi is aarch64
        arch = "aarch64-linux"
    else:
        die(f"no system arch found for nixosConfigurations.{name}")
    if os.path.isdir(os.path.join(ROOT, "hosts", name)):
        hosts[name] = {"arch": arch}

if not hosts:
    die("extracted zero hosts from flake.nix — parser broken or tree wrong")

# every hosts/<dir> must be accounted for, or the parse missed something
on_disk = {d for d in os.listdir(os.path.join(ROOT, "hosts"))
           if os.path.isdir(os.path.join(ROOT, "hosts", d))}
missing = on_disk - set(hosts)
if missing:
    die(f"hosts/ dirs not matched to a nixosConfiguration: {sorted(missing)}")

# name prefix -> hardware class (the sanitized naming scheme is the article's
# public convention, so deriving from it leaks nothing)
CLASS = [("gpu-", "server"), ("srv-", "server"), ("pi-", "sbc"),
         ("vm-", "vm"), ("cloud-", "cloud-vm"), ("console-", "vm"),
         ("hyperv-", "server")]

def host_class(name):
    for prefix, cls in CLASS:
        if name.startswith(prefix):
            return cls
    return "sbc" if name == "docker" else "server"

nodes, edges = [], []
nas_users = set()
for name in sorted(hosts):
    conf_rel = f"hosts/{name}/configuration.nix"
    conf_path = os.path.join(ROOT, conf_rel)
    if not os.path.isfile(conf_path):
        die(f"{conf_rel} missing")
    conf = open(conf_path, encoding="utf-8").read()

    modules = sorted(set(re.findall(r'modules/([\w-]+)\.nix', conf)))

    if 'role = "server"' in conf and "services.k3s" in conf:
        k3s_role = "server"
    elif "k3s-agent" in modules or "services.k3s" in conf:
        k3s_role = "agent"
    else:
        k3s_role = None

    networks = sorted(set(
        f"vlan{i}" for i in re.findall(r'vlanConfig\.Id\s*=\s*(\d+)', conf)))
    if re.search(r'wireguard|wg0', conf):
        networks.append("wireguard")

    meta = {"arch": hosts[name]["arch"], "class": host_class(name),
            "modules": modules, "networks": networks}
    if k3s_role:
        meta["k3sRole"] = k3s_role
        edges.append({"from": f"host:{name}", "to": "cluster:k3s",
                      "kind": "member-of"})
    nodes.append({"id": f"host:{name}", "kind": "host", "label": name,
                  "layer": "hardware", "source": conf_rel, "meta": meta})

    # hors-IaC hardware, derived only from what this host's config touches:
    # a ups-master host has a UPS on its USB port; nas-wake or an NFS mount
    # means the NAS (the join merges external:nas with the k3s layer's)
    if "ups-master" in modules:
        nodes.append({"id": f"external:ups-{name}", "kind": "external",
                      "label": f"ups ({name})", "layer": "external",
                      "source": conf_rel, "meta": {"via": "ups-master"}})
        edges.append({"from": f"host:{name}",
                      "to": f"external:ups-{name}", "kind": "powered-by"})
    if "nas-wake" in modules or re.search(r'"nfs"|fsType = "nfs', conf):
        nas_users.add(f"host:{name}")

if nas_users:
    nodes.append({"id": "external:nas", "kind": "external", "label": "nas",
                  "layer": "external", "source": "modules/nas-wake.nix",
                  "meta": {"via": "nas-wake module, NFS mounts"}})
    for uid in sorted(nas_users):
        edges.append({"from": uid, "to": "external:nas", "kind": "uses"})

out = {"topologyVersion": 1, "repo": "nixos-iac-public", "layer": "hardware",
       "nodes": nodes, "edges": edges}
with open(os.path.join(ROOT, "topology.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"emit-topology: {len(nodes)} hosts, {len(edges)} edges")
