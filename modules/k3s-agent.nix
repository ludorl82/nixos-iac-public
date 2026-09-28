## Shared k3s agent config for the NixOS fleet nodes. They join the
## existing cluster (control-plane = cloud-01, reached at 198.51.100.7:6443 via
## the normal LAN gateway - pfSense routes 198.51.100.0/24 to cloud-01, no
## per-host WireGuard needed). Each host sets its own
## `services.k3s.extraFlags = [ "--node-ip=<vlan10 ip>" ]`.
##
## The join token is NOT in git - it's placed out-of-band at
## /etc/rancher/k3s/token (root-only) on each host, streamed from cloud-01's
## /var/lib/rancher/k3s/server/node-token, and referenced via tokenFile.
##
## Version: pinned to the same attribute the server uses, so the whole fleet
## runs one k3s. The unversioned `pkgs.k3s` is nixpkgs' *default* k3s, not its
## newest - it was 1.35.6 here while `k3s_1_36` (1.36.2+k3s1, the server's
## exact version) sat right next to it. Tracking the default meant the agents
## drifted a minor behind the server for no reason, and would have silently
## overtaken it the first time nixpkgs bumped that default past 1.36.2 --
## inverting the skew, which is the unsupported direction. The upgrade stays a
## deliberate one-line change instead of a side effect of `nix flake update`.
##
## 2026-08-09: that line now points at ./k3s-upstream.nix rather than
## `pkgs.k3s_1_36`, because nixpkgs still packages 1.36.2 at that attribute
## while upstream stable is 1.36.3. See that file — it is a stopgap and says
## how to undo it.
##
## mkDefault: pi-01/pi-02 must override this. They are built from
## nixos-raspberrypi's pinned nixpkgs (25.11), so they build the same
## expression against the top-level nixpkgs instead.
{ pkgs, lib, ... }:
{
  ## br_netfilter is loaded at BOOT, before k3s — not on demand.
  ##
  ## Left to load on demand it deadlocks the kernel on some boots. Caught
  ## with the stacks on gpu-02, 2026-09-26, first boot on 6.18.52:
  ##   - iptables-restore (kube-proxy) holds the nf_tables commit mutex and,
  ##     inside that batch, an xt_physdev match request_module()s br_netfilter;
  ##   - that modprobe runs br_netfilter_init → register_netdevice_notifier,
  ##     which needs RTNL — the module sits in state "Loading" forever;
  ##   - the CNI `bridge` plugin, creating cni0, holds RTNL inside
  ##     register_netdevice and waits in nf_tables_netdev_event for the
  ##     nf_tables mutex that iptables-restore holds.
  ## Three-way cycle, no way out but a reboot. Everything else that touches
  ## network config queues behind RTNL: udev, ipv6 addrconf, sshd-session (so
  ## sshd starts answering "Not allowed at this time"), and every container
  ## hook — the node stays Ready while no pod can start. It is a RACE: four
  ## nodes booted the same kernel fine and gpu-02 lost it. gaming-01 lost the
  ## same race on 2026-09-14, when it was blamed on the nvidia module; the
  ## stacks show no nvidia frame in the cycle. A slower boot (a GPU driver
  ## loading) only makes losing it likelier.
  ##
  ## With the module already live, the request_module() in the physdev check
  ## is a no-op and the cycle cannot form. Loading it early is also the
  ## standard Kubernetes node prerequisite anyway.
  boot.kernelModules = [ "br_netfilter" ];

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://198.51.100.7:6443";
    tokenFile = "/etc/rancher/k3s/token";
    package = lib.mkDefault (pkgs.callPackage ./k3s-upstream.nix { });
  };

  # k3s agent networking through the NixOS firewall: flannel vxlan (8472/udp)
  # + kubelet (10250/tcp), and trust the CNI/flannel interfaces so pod and
  # service traffic isn't dropped (the firewalld-equivalent gotcha that bit
  # Frigate's k3s migration on the old gpu-02).
  networking.firewall = {
    trustedInterfaces = [ "cni0" "flannel.1" ];
    # UniFi network application: it runs hostNetwork and is NOT pinned to a
    # node, so any agent can end up hosting it - open its ports fleet-wide
    # rather than per-host. 8443 UI, 8080 device inform, 8880/8843 guest
    # portal, 6789 speed test, 3478/udp STUN, 10001/udp device discovery.
    # (gpu-01, where this ran before, had no host firewall at all - hence the
    # UI and AP adoption silently breaking on the first NixOS node.)
    allowedTCPPorts = [ 10250 6789 8080 8443 8843 8880 ];
    allowedUDPPorts = [ 8472 3478 10001 ];
  };

  # NFS client support for the cluster's nfs-client StorageClass (QNAP
  # 192.0.2.65). Without nfs-utils on the k3s unit's PATH the kubelet
  # falls back to a raw mount(2) and every NFS PVC fails with
  # "NFS: mount program didn't pass remote address".
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;
  systemd.services.k3s.path = [ pkgs.nfs-utils ];
}
