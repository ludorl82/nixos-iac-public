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
## inverting the skew, which is the unsupported direction. An explicit
## versioned attribute makes the k3s upgrade a deliberate one-line change
## (_1_36 -> _1_37) instead of a side effect of `nix flake update`.
##
## mkDefault: pi-01/pi-02 must override this. They are built from
## nixos-raspberrypi's pinned nixpkgs (25.11), which has no k3s_1_36 at all,
## so they source the same version from the top-level nixpkgs instead.
{ pkgs, lib, ... }:
{
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://198.51.100.7:6443";
    tokenFile = "/etc/rancher/k3s/token";
    package = lib.mkDefault pkgs.k3s_1_36;
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
