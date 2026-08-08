## console-vm: the console VM on gpu-01 — the interactive admin workspace,
## reborn as a dedicated VM in the 2026-08-07 jumphost/console split (the
## name previously meant the Pi-4 jumphost, then a DNS alias to pi-02).
## Same libvirt/macvtap shape as vm-01-on-gpu-01: guest sits directly on
## VLAN10 (untagged to the guest), static IP matched by the VM's fixed MAC.
##
## Deliberately NOT a k3s agent — the console manages the cluster, it
## doesn't join it. Its home directory is seeded from the nightly S3
## tarball + git clones (scripts/seed-console-home.sh); the machine itself
## is disposable.
##
## Out-of-band seeds at install time (nixos-anywhere --extra-files):
##   /etc/comin/github-token   — comin GitOps enrollment
##   /var/lib/console/env      — PASS=<console user password>
##   /var/lib/console/ssh/     — the container's stable sshd host keys
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/private-ca.nix
    ../../modules/jumphost-tools.nix
    ../../modules/console-container.nix
  ];

  # The real console: autoStart (the default) with room to work — the whole
  # point of the move off the 4 GiB Pi. VM gets 16 GiB; the container cap
  # leaves headroom for the host and nested docker builds.
  homelab.console.memoryLimit = "12g";
  homelab.console.memorySwap = "16g";
  # amd64 build of 2026-08-07 (gpu-01, console-entry.sh shim included) — the
  # x86_64 counterpart of pi-02's arm64 pin. Registry tag :arm64 preserves
  # the old manifest from GC; a true multi-arch index replaces both pins
  # when pi-02's container next updates (Phase 4/5).
  homelab.console.image = "docker.lab.example:5000/console-personal@sha256:5f420318906472e1f9804e21ef8ce8eaf03c9191a8edbd4d656a3d05b8f15dad";
  # /var/lib/console/ssh was seeded at install (pi-02's container key) —
  # the :2222 identity is therefore the SAME as today's console.
  homelab.console.stableHostKeys = true;

  networking.hostName = "console-vm";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      # IPv6 follows the hex(last-octet) convention (136 -> 0x88). Reachable
      # inbound only because this VM's macvtap <interface> carries
      # trustGuestRxFilters='yes' AND model virtio - see
      # hosts/console-vm/libvirt-domain.xml.
      Address = [
        "192.0.2.136/23"
        "2001:db8:50:a::88/64"
      ];
      Gateway = "192.0.2.254";
      DNS = "192.0.2.254";
      IPv6AcceptRA = true;
    };
    # NB: no RequiredForOnline=no here - it's the primary NIC, and setting
    # that makes systemd-networkd-wait-online fail (vm-02 lesson). Also add
    # the "~." domain so systemd-resolved routes all lookups at pfSense
    # (vm-02 lesson - otherwise internal names fall to public fallback DNS).
    domains = [ "lab.example" "example.com" "~." ];
  };
  # Untagged VLAN50, via a SECOND macvtap interface on gpu-01's `eno2` (VLAN50
  # is the untagged/native VLAN on that trunk; `vlan10` is the tagged
  # sub-interface the primary NIC rides on). Secondary: address only,
  # deliberately no gateway, so the default route stays exclusively on
  # VLAN10. RequiredForOnline=no is correct HERE - it is wrong on 10-lan
  # above, which is the link wait-online must actually wait for.
  systemd.network.networks."20-vlan50" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig.Address = "203.0.113.136/23";
    linkConfig.RequiredForOnline = "no";
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.ludorl82 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      # The one Cronicle job that follows the console: Weekly IaC update PRs
      # hits the CONTAINER on :2222, but the key lands in the container's
      # ~/.ssh/authorized_keys via console-container.nix's render of this
      # host list.
      ''command="/home/ludorl82/scripts/weekly-iac-updates.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      # Nightly console-home backup (the console-vm/ S3 prefix resumes on this
      # VM). Dedicated keypair per (script, host) policy — Secret
      # cronicle-ssh-backup-console-vm, event "Homelab Backup (console-vm VM)".
      ''command="/home/ludorl82/scripts/homelab-backup.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      # Nightly diagram sync (network-diagram.md reconcile + blog shape
      # diagram) — Secret cronicle-ssh-diagram-sync, event "Nightly Diagram
      # Sync". Runtime copy in ~/scripts like its siblings.
      ''command="/home/ludorl82/scripts/nightly-diagram-sync.sh",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example''
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example fleet-deploy"
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  system.stateVersion = "26.05";
}
