## vm-03: the cluster's GPU node — a NixOS libvirt VM on `gaming-01`, with the
## GTX 960 passed through. Recreated 2026-09-14; the name last belonged to a
## Hyper-V VM on this same host, retired during the NixOS conversion.
##
## WHY A VM AND NOT THE HOST. gaming-01 has a spare GPU and k3s wants one, so the
## obvious move was to give the card to gaming-01's own kubelet. That was tried
## on 2026-09-14 and it deadlocked the kernel roughly four minutes into every
## boot: a hung-task chain headed by `iptables-restor`, `bridge` waiting on it,
## and `k3s-agent`, `modprobe`, a udev-worker and a kworker all waiting on
## `bridge`. A wedged modprobe serialises every later module load, so k3s never
## got br_netfilter, its iptables rules never landed, and CreatePodSandBox timed
## out — while the node still reported Ready with a renewing Lease. Putting the
## driver inside a VM instead keeps the nvidia module out of the host kernel
## entirely, which is the whole point of this host: gaming-01's kernel stays a
## plain libvirt + k3s kernel, and anything nvidia does, it does in here.
##
## THREE cards, not one. Its own is the GTX 960 (GM206, 10de:1401) at
## 0000:17:00.0. It ALSO borrows both RTX 3050s — arcade1's GA106 (10de:2507)
## at 65:00.0 and arcade2's GA107 (10de:2584) at b4:00.0 — because they sit
## idle whenever nobody is playing, which is almost always. Every slot's IOMMU
## group holds only that card and its audio function. gaming-01 binds all six
## functions to vfio-pci by id; see hosts/gaming-01/configuration.nix.
##
## THE BORROWING IS WHY THE HANDOFF MUST BE ORDERED. libvirt refuses to start a
## domain whose PCI device is already claimed by another, so vm-03 has to be
## fully stopped before an arcade guest starts. `arcade-ctl` on gaming-01 — the
## path Home Assistant uses — does that synchronously and waits. The libvirt
## qemu hook only fires a best-effort asynchronous stop, because a hook that
## blocks on libvirtd can deadlock the very VM it is trying to start; treat it
## as a safety net for a `virsh start` typed by hand, not as the mechanism.
##
## One driver covers all three: legacy_580 supports Maxwell AND Ampere.
##
## GAME MODE. gaming-01 is also a gaming host, and its libvirt hook shuts this VM
## down when an arcade guest starts, bringing it back afterwards. That was
## already wanted for CPU reasons — the box has 6 cores, and leaving 4 vCPU of
## cluster work running during a game is the waste the existing drain avoids —
## and it became REQUIRED once this VM started borrowing the arcade GPUs.
## So this node comes and goes, several times an evening potentially: do not
## put anything on it that cannot be rescheduled, and nothing that needs the
## same GPU to still be there ten minutes later.
##
## Single-homed on VLAN10 on purpose, unlike vm-02: a compute node has no
## business on the home LAN, and every multi-homing attempt on this host has
## cost us something (see the arcade VLAN50 removal).
##
## hardware-configuration.nix (virtio initrd modules) is generated on the booted
## installer during the nixos-anywhere run — omitting it makes the install
## unbootable.
{ config, lib, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ../../modules/k3s-agent.nix ../../modules/private-ca.nix ];

  ## gpu=nvidia matches gpu-02's label so a GPU workload can select either
  ## node. No taint: this node is small and comes and goes, but nothing about
  ## it is reserved.
  services.k3s.extraFlags = [
    "--node-ip=192.0.2.135"
    "--node-label=gpu=nvidia"
  ];

  networking.hostName = "vm-03";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "02:00:00:00:00:01";
    networkConfig = {
      # IPv4 ONLY on this macvtap, exactly like the arcade guests on this same
      # host. gaming-01's VLAN10 reflects the guest's own IPv6 NDP/DAD multicast
      # back to it, so the link-local address fails duplicate-address detection
      # in an endless loop, the link never leaves "configuring", and the static
      # IPv4 never commits. vm-02 carries an IPv6 address happily because it
      # lives on srv-01, where this does not happen — do not copy it here.
      # (The hex(last-octet) convention would have made this ::87.)
      Address = [ "192.0.2.135/23" ];
      Gateway = "192.0.2.254";
      DNS = [ "192.0.2.254" ];
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
    # "~." routes every lookup at pfSense's Unbound; without it resolved only
    # consults it for the search domains and sends the rest to public
    # fallbacks, which cannot see the internal zone.
    domains = [ "lab.example" "example.com" "~." ];
    # No RequiredForOnline override: this is the only interface, so
    # systemd-networkd-wait-online must actually wait for it. Marking it
    # optional is what made vm-02 fail wait-online on every boot.
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  ## --- The passed-through GTX 960 -------------------------------------------
  ## PINNED to legacy_580 and this is NOT a preference: the 960 is Maxwell
  ## (GM206), which NVIDIA moved to legacy support at the 580 branch. On
  ## `stable`/`production` (595.84) this card gets no driver at all, and the
  ## failure is silent — CUDA simply finds no device. 580.173.02 is the LTSB
  ## for Maxwell/Pascal/Volta, supported until Aug 2028; after that the card
  ## needs replacing, not updating.
  ##
  ## COST TO KNOW ABOUT: legacy_580 is NOT in the binary cache, so any rebuild
  ## that changes the kernel compiles the module here — roughly ten minutes. If
  ## that build fails, comin leaves this guest on its previous generation.
  ##
  ## `open = false` is equally forced: the open kernel modules need Turing or
  ## newer.
  ##
  ## `services.xserver.videoDrivers = [ "nvidia" ]` WITHOUT enabling the X
  ## server looks wrong on a headless compute node, and it is load-bearing
  ## anyway: it is how NixOS decides the proprietary driver is installed, and
  ## hardware.nvidia-container-toolkit asserts on it — dropping it fails
  ## evaluation with "requires nvidia drivers: ... add \"nvidia\" to
  ## services.xserver.videoDrivers". `services.xserver.enable` stays false, so
  ## no X is ever started; only the driver comes along. gpu-02 carries the
  ## same pair.
  nixpkgs.config.allowUnfree = true;
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    open = false;
    modesetting.enable = false;
    nvidiaSettings = false;
  };
  boot.blacklistedKernelModules = [ "nouveau" ];

  ## CDI for k3s — gpu-02's recipe, see hosts/gpu-02/configuration.nix for
  ## the long version. Short: k3s scans $PATH at startup to decide whether to
  ## register an nvidia runtime, the runtime binaries live in the toolkit's
  ## `tools` OUTPUT (the default output only ships nvidia-ctk),
  ## nvidia-container-runtime needs `runc` on its own PATH, and workloads must
  ## ask for `runtimeClassName: nvidia-cdi` — plain `nvidia` injects the device
  ## nodes but none of the /nix/store driver userspace, giving you /dev/nvidia0
  ## and no libcuda.
  ##
  ## A REBOOT is required after the first install: until the kernel module is
  ## loaded, nvidia-container-toolkit-cdi-generator.service fails with
  ## "failed to initialize NVML: Driver Not Loaded" and writes no spec.
  hardware.nvidia-container-toolkit.enable = true;
  systemd.services.k3s.path = [
    pkgs.nvidia-container-toolkit.tools
    pkgs.nvidia-container-toolkit
    pkgs.runc
  ];

  ## qemu-guest-agent: lets gaming-01 do a clean guest shutdown, which is what the
  ## game-mode hook uses to stop this VM before a gaming session. Without it the
  ## hook can only destroy the VM. The channel is in libvirt-domain.xml.
  services.qemuGuest.enable = true;

  environment.systemPackages = [ pkgs.pciutils ];

  users.users.ludorl82 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  system.stateVersion = "26.05";
}
