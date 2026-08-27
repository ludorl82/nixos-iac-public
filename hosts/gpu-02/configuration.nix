## NixOS config for gpu-02 - the dedicated Frigate NVR / GPU node.
## Frigate was parked on gpu-01 while this box was converted to NixOS
## (2026-07-24) and is being brought back here, so this config now carries
## the three things that role needs on top of the minimal base: the NVIDIA
## driver stack for the RTX 3060, the frigate-lv data mount, and the
## k3s node taint/label that keeps gpu-02 exclusively Frigate's.
##
## hardware-configuration.nix carries the initrd storage modules
## (ahci/sd_mod/...) - omitting those is what made srv-01's first
## install unbootable, so it's imported here from the start.
##
## systemd-networkd VLAN10 config (proven pattern), static 192.0.2.98.
{ config, lib, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ../../modules/k3s-agent.nix ../../modules/private-ca.nix ../../modules/ups-client.nix ];

  ## --node-taint/--node-label only take effect at first registration, so
  ## on an already-joined node they must also be applied with kubectl once.
  ## The taint is load-bearing beyond just reserving the box: it keeps the
  ## svclb-traefik daemonset OFF gpu-02, which is what stops k3s's
  ## ServiceLB from swallowing host ports 80/443 node-wide (the gotcha that
  ## bit us on gpu-01, where a host nginx bound fine but got zero traffic).
  services.k3s.extraFlags = [
    "--node-ip=192.0.2.98"
    "--node-label=gpu=nvidia"
    "--node-taint=dedicated=frigate:NoSchedule"
  ];

  ## RTX 3060 Laptop (GA106M, 10de:2520). Frigate uses it three ways: the
  ## ONNX detector's TensorRT execution provider, NVDEC hwaccel for camera
  ## decode, and nvenc for the low-res long-term feed below.
  nixpkgs.config.allowUnfree = true;
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.production;
    open = false;
    modesetting.enable = true;
    nvidiaSettings = false;
  };
  hardware.nvidia-container-toolkit.enable = true;
  ## k3s writes its own containerd config and auto-adds an `nvidia` runtime
  ## (which is what the Frigate pod's `runtimeClassName: nvidia` selects)
  ## only if it finds `nvidia-container-runtime` while scanning $PATH at
  ## startup. On a normal distro that's /usr/bin; on NixOS it's a /nix/store
  ## path k3s would never look in, so put it on the k3s unit's PATH.
  ## Two traps here, both cost time:
  ##   - the runtime binaries are in the toolkit's `tools` OUTPUT; the
  ##     default output only ships `nvidia-ctk` and detection silently fails.
  ##     BOTH outputs are needed: the runtime bakes a createContainer hook
  ##     into the OCI spec and resolves `nvidia-ctk` off its own PATH,
  ##     falling back to a hardcoded /usr/bin/nvidia-ctk that will never
  ##     exist here ("error running createContainer hook #0: fork/exec
  ##     /usr/bin/nvidia-ctk: no such file or directory").
  ##   - nvidia-container-runtime is a shim that execs a real low-level
  ##     runtime and looks for `runc`/`crun` on ITS OWN PATH, so runc has to
  ##     be here too or every container on this node dies with
  ##     "no runtime binary found from candidate list: [runc crun]".
  systemd.services.k3s.path = [
    pkgs.nvidia-container-toolkit.tools
    pkgs.nvidia-container-toolkit
    pkgs.runc
  ];

  environment.systemPackages = [ pkgs.pciutils ];

  ## Frigate runs with hostNetwork, so its ports are bound on gpu-02's own
  ## VLAN10 address and every consumer reaches them over the LAN, NOT through
  ## the pod network - the k3s-agent module's trustedInterfaces (cni0,
  ## flannel.1) do NOT cover this. That includes Traefik: the frigate Service
  ## endpoint resolves to 192.0.2.98:5000, which is off-cluster as far as
  ## routing is concerned, so an ingress request from the Traefik pod lands
  ## on vlan10 and gets dropped unless 5000 is open here. Symptom is a
  ## frigate.lab.example request that just hangs. This is the NixOS-firewall
  ## restatement of the firewalld problem that broke the original k3s
  ## migration on this same host.
  ##   5000 api/UI, 1984 go2rtc, 8554 RTSP (HA + the low-res feed),
  ##   8555 WebRTC (tcp+udp).
  networking.firewall = {
    allowedTCPPorts = [ 5000 1984 8554 8555 ];
    allowedUDPPorts = [ 8555 ];
  };

  ## Frigate's config + ~78G of recordings. This LV survived the NixOS
  ## reinstall untouched (disko only ever formatted the OS SSD), so it
  ## still holds the tree as of the move to gpu-01 - the cutover only has to
  ## rsync the delta back, not 78G.
  fileSystems."/home/ludorl82/opt/frigate" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
  };

  ## --- Frigate side-cars (were plain systemd + crontab on Ubuntu) -------
  ##
  ## The shell/python jobs themselves deliberately stay on the frigate LV
  ## under .../scripts rather than moving into the nix store: they're
  ## operational scripts the user edits in place, and keeping the paths
  ## identical to the Ubuntu setup means the Kuma push monitors and the NAS
  ## backup keep working with zero changes elsewhere. Only the *schedule*
  ## and the *environment* are declared here.

  ## Long-term low-res archive feed: re-encodes the ad410-avant RTSP stream
  ## to a tiny 640x480 h264_nvenc segment file every 5 min, which the cloud-01
  ## sync job pulls to S3. Reads from Frigate's own go2rtc on localhost,
  ## so it just retries until the Frigate pod is up - no ordering needed
  ## beyond the network and the data mount.
  systemd.services.frigate-lowres-feed = {
    description = "Low-res long-term video feed for ad410-avant (S3 archive source)";
    after = [ "network-online.target" "home-ludorl82-opt-frigate.mount" ];
    wants = [ "network-online.target" ];
    requires = [ "home-ludorl82-opt-frigate.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "ludorl82";
      Restart = "always";
      RestartSec = 5;
    };
    ## nvenc is dlopen'd (libnvidia-encode.so.1) rather than linked, and on
    ## NixOS that library only exists under /run/opengl-driver/lib, which
    ## isn't on the default loader path for a systemd unit.
    environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    ## Written as a script (not a raw ExecStart=) so ffmpeg's strftime
    ## pattern doesn't have to be %%-escaped for systemd.
    script = ''
      exec ${pkgs.ffmpeg-full}/bin/ffmpeg -rtsp_transport tcp \
        -i rtsp://127.0.0.1:8554/ad410-avant \
        -vf scale=640:480 -c:v h264_nvenc -b:v 120k -maxrate 150k \
        -bufsize 300k -an \
        -f segment -segment_time 300 -segment_format mp4 \
        -reset_timestamps 1 -strftime 1 \
        /home/ludorl82/opt/frigate/lowres/ad410-avant/%Y%m%d_%H%M%S.mp4
    '';
  };

  ## Sub-hourly jobs stay in host cron on purpose - they were deliberately
  ## moved back OUT of Cronicle, which only holds daily/weekly work.
  ## cron hands each line to sh with a near-empty PATH, so every job gets an
  ## explicit PATH; the scripts shell out to curl/rsync/ssh/find/systemctl.
  services.cron = {
    enable = true;
    systemCronJobs =
      let
        binPath = lib.makeBinPath [
          pkgs.bash pkgs.coreutils pkgs.curl pkgs.rsync pkgs.openssh
          pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.util-linux
          pkgs.systemd pkgs.python3
        ];
        s = "/home/ludorl82/opt/frigate/scripts";
      in [
        "*/5  * * * * root      PATH=${binPath} ${pkgs.python3}/bin/python3 ${s}/frigate_recording_watchdog.py >> /var/log/frigate_recording_watchdog.log 2>&1"
        "*/10 * * * * ludorl82  PATH=${binPath} ${s}/lowres_feed_watchdog.sh"
        "15   * * * * ludorl82  PATH=${binPath} ${s}/backup_to_nas.sh >> ${s}/backup_to_nas.log 2>&1"
        "20   * * * * ludorl82  PATH=${binPath} ${s}/prune_lowres.sh"
      ];
  };

  ## The minimal base left this at the NixOS default of UTC, which broke two
  ## things at once: Frigate's pod bind-mounts /etc/localtime as a hostPath
  ## with `type: File`, and on a stock NixOS that path doesn't exist at all,
  ## so the pod hangs in ContainerCreating on FailedMount; and the low-res
  ## feed names its segments with a local-time strftime pattern. Matches the
  ## Ubuntu install this host replaced (and gpu-01, where Frigate was parked).
  time.timeZone = "America/Toronto";

  networking.hostName = "gpu-02";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    netdevs."10-vlan10" = {
      netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
      vlanConfig.Id = 10;
    };
    # Untagged = VLAN50. Secondary: address only, deliberately NO gateway, so
    # the default route stays exclusively on VLAN10 - that's also what keeps
    # cloud-01 reachable over the WireGuard tunnel (a VLAN50 default route would
    # send tunnel replies out the wrong interface). Not required for
    # network-online so a VLAN50 hiccup can't hang boot.
    networks."10-eno1" = {
      matchConfig.Name = "eno1";
      vlan = [ "vlan10" ];
      address = [ "203.0.113.98/23" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # Tagged VLAN10 = primary, and the only interface with a gateway.
    # IPv6 follows the hex(last-octet) convention (98 -> 0x62); the v6
    # default route comes from pfSense's RA.
    networks."20-vlan10" = {
      matchConfig.Name = "vlan10";
      address = [
        "192.0.2.98/23"
        "2001:db8:50:a::62/64"
      ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig.DNS = "192.0.2.254";
      networkConfig.IPv6AcceptRA = true;
      # "~." makes pfSense's Unbound the resolver for *everything*. Without
      # it systemd-resolved falls back to its built-in public servers
      # (1.1.1.1 & co.), which cannot resolve the internal lab.example zone:
      # public names work, every homelab name is NXDOMAIN. Same trap as
      # vm-03. Here it silently broke all three Frigate Kuma push
      # monitors - the watchdog scripts log a push failure and still exit 0,
      # so the only symptom would have been monitors going stale.
      domains = [ "lab.example" "example.com" "~." ];
    };
  };
  networking.search = [ "lab.example" "example.com" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.ludorl82 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      # gpu-01 is the fleet's build/deploy host (same key vm-03 carries); it
      # also had to push Frigate's data back here during the gpu-01->gpu-02
      # migration, which is what finally backfilled this.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      # cloud-01 pulls the low-res segments off this host every few minutes and
      # ships them to S3 (/opt/scripts/sync_frigate_lowres.py).
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  system.stateVersion = "26.05";
}
