## NixOS config for bob - the amd64 workhorse (3x RTX 3060, 109G RAM,
## 931G NVMe). Converted last in the fleet since it was the Nix build host
## + k3s workload home; its services were migrated off first (see the bob
## drain). Minimal base + k3s here; the two follow-ups its old role needs:
##   - NVIDIA driver stack for the 3x RTX 3060 (general GPU capacity)
##   - libvirtd, if bob hosts VMs again (worker3/cp-3 are retired, so
##     omitted for now)
## Both mirror encodeur's nvidia block / vega's libvirtd block when
## wanted.
##
## hardware-configuration.nix (initrd storage modules incl. nvme) is
## generated on the booted installer during nixos-anywhere and imported
## here - omitting it makes the install unbootable.
##
## Network: single-homed VLAN10 tagged on eno2 (eno1 is unused/down),
## static 192.0.2.129 + IPv6 ::81 (hex(129)=0x81). Same systemd-networkd
## shape as vega, parent eno2 instead of eno1.
{ config, lib, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/k3s-agent.nix
    ../../modules/private-ca.nix
    ../../modules/ups-cp-1.nix
    ../../modules/vm-host.nix
    ../../modules/caps-ctrl.nix
  ];

  # Killpower OPT-OUT for the rolling rack (drill #2 lesson, 2026-08-04):
  # the LX1500GU never restores output on its own after a full power-off —
  # front-button only, no auto-restart toggle exists on this firmware. So
  # cutting output guarantees a stranded rack. Instead: a UPS-driven
  # shutdown leaves the outlets HOT, the four BMCs stay powered (~5 W on
  # the battery's post-FSD reserve, then mains), and worker2's rack-wake
  # latch (modules/rack-wake.nix, powered by the survivor OR700 with
  # pfSense) IPMI-powers everything back on when the mains return.
  systemd.shutdown."nut-killpower" =
    lib.mkForce (pkgs.writeShellScript "nut-killpower-disabled" "exit 0");

  # Fire the low-battery cascade at 50 % instead of the unit's 10 %: with
  # outlets staying hot (no killpower), the remaining half feeds the four
  # BMCs (~5 W) for many hours of wake-latch runway, and the earlier
  # trigger keeps well clear of the battery gauge's post-deep-cycle lies
  # (drill #2: "34 %" collapsed to LB instantly). Driver-level override —
  # NUT synthesizes LB at this threshold regardless of UPS firmware.
  # ignorelb is REQUIRED for the override to matter: without it usbhid-ups
  # only raises LB when the UPS firmware says so (found live 2026-08-04 —
  # the cascade sat idle at 49% until the unit's own 10%-ish signal fired).
  # With ignorelb the driver evaluates charge/runtime against the .low
  # values itself.
  # runtime.low: with ignorelb the driver ALSO raises LB when the firmware's
  # runtime estimate dips to battery.runtime.low (default 300 s) — even
  # on mains. At 50-70 % load the LX1500GU's estimate oscillates 300-690 s
  # and tripped a false "battery is low" ntfy on 2026-08-23 16:19 (OL,
  # 100 %). Drop the runtime floor so LB is decided by charge alone.
  power.ups.ups.qnapups.directives = [
    "override.battery.charge.low = 50"
    "override.battery.runtime.low = 60"
    "ignorelb"
  ];
  # gpu=nvidia matches the label encodeur carries, so a GPU workload can be
  # steered here by label instead of by hostname. CAVEAT, the same one
  # encodeur's config records: --node-label only takes effect at FIRST
  # registration, so on this already-joined node it was also applied once by
  # hand (`kubectl label node bob gpu=nvidia`). The flag is here so a reimage
  # converges on its own.
  services.k3s.extraFlags = [ "--node-ip=192.0.2.129" "--node-label=gpu=nvidia" ];

  # bob is the fleet's builder ("no heavy lifting on aws"): emulated
  # aarch64 lets it build the Pi images (docker-rpi4, worker sticks)
  # without needing a Pi with spare RAM.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # bob builds images and pushes them to the fleet registry on the docker
  # host — https://docker.lab.example:5000, private-CA TLS trusted via
  # private-ca.nix, so no insecure-registries needed. The leaf carries the
  # DNS name plus both IP SANs, so IP-addressed pushes verify as well.
  virtualisation.docker.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "bob";
  # Routage par source pour la patte VLAN50 : voir modules/dual-homed-routing.nix.
  labo.dualHomed = {
    enable = true;
    octet = 129;
    vlan10Network = "30-mvhost";
    vlan50Network = "25-mvhost50";
  };
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    netdevs."10-vlan10" = {
      netdevConfig = { Name = "vlan10"; Kind = "vlan"; };
      vlanConfig.Id = 10;
    };
    # macvtap host<->guest fix: a macvtap guest (worker3) can't reach the host
    # stack on its own parent (vlan10), so bob's VLAN10 IP lives on a MACVLAN
    # over vlan10 to join that L2 domain - without it flannel bob<->worker3 is
    # dropped. Mirrors the old Ubuntu bob's macvlan-host@vlan.10.
    netdevs."15-mvhost" = {
      netdevConfig = { Name = "mvhost"; Kind = "macvlan"; };
      macvlanConfig.Mode = "bridge";
    };
    # The same fix is needed on the VLAN50 side: worker3 has a macvtap on
    # the untagged eno2 too, so bob's own VLAN50 address has to move off
    # eno2 onto a macvlan or worker3 can't reach it either. (The vlan10 half
    # above was done first and left this half broken - worker3 could reach
    # bob on VLAN10 but not on VLAN50.) Mirrors vega/worker4.
    netdevs."16-mvhost50" = {
      netdevConfig = { Name = "mvhost50"; Kind = "macvlan"; };
      macvlanConfig.Mode = "bridge";
    };
    # Untagged = VLAN50. Secondary: address only, deliberately NO gateway, so
    # the default route stays exclusively on VLAN10 - that's also what keeps
    # aws reachable over the WireGuard tunnel. Not required for
    # network-online so a VLAN50 hiccup can't hang boot. This is also the
    # parent that worker3's second (VLAN50) macvtap NIC hangs off.
    networks."10-eno2" = {
      matchConfig.Name = "eno2";
      vlan = [ "vlan10" ];
      macvlan = [ "mvhost50" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # bob's VLAN50 address, on the macvlan (moved off eno2 so the macvtap
    # guest can reach it). Secondary: address only, no gateway.
    networks."25-mvhost50" = {
      matchConfig.Name = "mvhost50";
      address = [ "203.0.113.129/23" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # vlan10 now just parents the macvlan + brings the link up - no IP here.
    networks."20-vlan10" = {
      matchConfig.Name = "vlan10";
      macvlan = [ "mvhost" ];
      networkConfig.DHCP = "no";
      linkConfig.RequiredForOnline = "no";
    };
    # bob's actual VLAN10 host address, on the macvlan.
    networks."30-mvhost" = {
      matchConfig.Name = "mvhost";
      address = [
        "192.0.2.129/23"
        "2001:db8:50:a::81/64"
      ];
      routes = [ { Gateway = "192.0.2.254"; } ];
      networkConfig = { DHCP = "no"; DNS = "192.0.2.254"; IPv6AcceptRA = true; };
      domains = [ "lab.example" "example.com" "~." ];
    };
  };
  networking.search = [ "lab.example" "example.com" ];

  users.users.ludorl82 = {
    isNormalUser = true;
    # Console password (iKVM, rack screen) = KeePass entry "Linux", asked for
    # on 2026-10-09. Only its sha-512 HASH, seeded by hand on the host (root
    # 600, never in git: the repo is published sanitized and a published hash
    # can be cracked offline). sudo does not ask for it (wheelNeedsPassword =
    # false) and SSH stays key-only. Missing file = the account stays locked.
    hashedPasswordFile = "/var/lib/secrets/ludorl82.hash";
    # Just an admin login now — the video/render groups were only for
    # gnome-shell's GPU access, dropped with the desktop (2026-08-18).
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example"
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # libvirt/qemu-kvm host - bob hosts the worker3 NixOS VM (macvtap on
  # vlan10), same as vega hosts worker4. virt-manager provides
  # virt-install; OVMF/UEFI firmware ships by default.
  virtualisation.libvirtd.enable = true;
  # On host power-off, gracefully ACPI-shut-down guests and cold-start them on
  # boot. This is the correct treatment for worker3 (a k3s node — clean shutdown
  # + cold rejoin beats suspend/resume, which strands it with a stale clock and
  # etcd-lease churn). coquille and win11 are the EXCEPTION: labo.vmHost's
  # vm-always-on (below) saves/restores their RAM state so they survive a bob
  # power-cycle unchanged. Its ExecStop runs (ordered before libvirt-guests
  # stops) while they are still up, managedsaves them, so libvirt-guests then
  # finds them already down and skips them. bob's HA "off" is a graceful BMC
  # `power soft`, so these hooks run.
  virtualisation.libvirtd.onShutdown = "shutdown";
  virtualisation.libvirtd.onBoot = "start";

  # coquille and win11 can live here or on stella and move between them while
  # running: `sudo vm-move <vm> <host>` (modules/vm-host.nix). Whichever host
  # defines them saves them to disk on shutdown and resumes them on boot —
  # the job bob's own vm-suspend-coquille did until 2026-10-08.
  labo.vmHost = {
    enable = true;
    alwaysOn = [ "coquille" "win11" ];
    vncProxies.win11 = 5903;
  };

  # No forced console mode: the ast driver uses an EDID (even a forced one)
  # only when a monitor answers on DDC, and rejects the 1080p `video=` builds
  # (negative hsync) — read in drivers/gpu/drm/ast (6.18) on 2026-10-09. The
  # console stays 1024x768 until a VGA EDID emulator sits between the port and
  # the VGA switch (net-cfgs backlog).

  # No rack kiosk here since 2026-10-09: a kiosk on the ASPEED hid bob's own
  # console from its iKVM. The kiosk lives on stella's RTX 3050 (HDMI), and
  # bob's console is its desktop 4 there (modules/kiosk.nix).

  # 3x RTX 3060 (GA106) since 2026-09-11, when the third card arrived from
  # stella. Same stack as encodeur - see that host's config for the full
  # rationale on the k3s PATH traps below (they cost real time there).
  #
  # ALL THREE GO TO OLLAMA since 2026-09-15:
  #
  #   0000:17:00.0  GPU-00000000-0000-0000-0000-000000000000
  #   0000:65:00.0  GPU-00000000-0000-0000-0000-000000000000
  #   0000:b4:00.0  GPU-00000000-0000-0000-0000-000000000000
  #
  # The history is worth three lines because the shape flipped twice. 17:00.0
  # arrived from stella on 2026-09-11. On the 12th it was reserved for the
  # cluster with the embeddings pod as its consumer, on the 13th that was
  # undone for a dense 27B, and the same evening it was put back — the 27B
  # read prompts too slowly, and the 3050 that was to carry the cluster's GPU
  # went into arcade1 instead. So the reservation stood for lack of anywhere
  # better.
  #
  # Now there IS somewhere better. worker5, a libvirt VM on stella with three
  # cards of its own and a working CDI spec, became the cluster's GPU node on
  # 2026-09-14. Reserving a card here as well reserved the same capacity
  # twice, so this host stops doing it. (worker5 was retired on 2026-09-26;
  # the mandate rests on stella's and encodeur's own cards now, and still not
  # here.) What did NOT follow the mandate is
  # bge-m3 — see the ollama block below for why serving the site's embeddings
  # from a VM that game mode shuts down would have been a silent regression.
  # The three cards, as `lspci -nn -d 10de:` and `nvidia-smi` printed them on
  # 2026-09-16. Read off the host because the comments in this very file could
  # not agree: line 1 and line 5 said "2x RTX 3060", line 205 said "3x RTX 3060
  # since 2026-09-11", line 270 said "the two 3060s".
  #
  # They are not three of the same part — 17:00.0 and 65:00.0 report 10de:2503,
  # b4:00.0 reports 10de:2504, the Lite Hash Rate variant. Same name, same 12
  # Go, different silicon binning. Nothing here depends on the difference
  # today; it is recorded because guessing "a 3060 is a 3060" is exactly the
  # mistake hosts/stella/configuration.nix documents having made with the 3050s.
  #
  # No passthrough on this host: all three are driven by the host for ollama.
  labo.gpus = [
    { slot = "17:00.0"; id = "10de:2503"; audioId = "10de:228e"; model = "RTX 3060"; die = "GA106"; vram = "12 Go"; }
    { slot = "65:00.0"; id = "10de:2503"; audioId = "10de:228e"; model = "RTX 3060"; die = "GA106"; vram = "12 Go"; }
    { slot = "b4:00.0"; id = "10de:2504"; audioId = "10de:228e"; model = "RTX 3060 Lite Hash Rate"; die = "GA106"; vram = "12 Go"; }
  ];

  nixpkgs.config.allowUnfree = true;
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    package = import ../../modules/nvidia-driver.nix {
      inherit (config.boot.kernelPackages) nvidiaPackages;
    };
    open = false;
    modesetting.enable = true;
    nvidiaSettings = false;
  };
  hardware.nvidia-container-toolkit.enable = true;
  # k3s only auto-registers the `nvidia` containerd runtime if it finds
  # nvidia-container-runtime on its PATH at startup; the runtime binaries
  # live in the toolkit's `tools` output (BOTH outputs needed), and the
  # runtime shim needs runc on its PATH too. This list MERGES with the
  # k3s-agent module's nfs-utils entry.
  systemd.services.k3s.path = [
    pkgs.nvidia-container-toolkit.tools
    pkgs.nvidia-container-toolkit
    pkgs.runc
  ];

  # This host runs HEADLESS. Gaming moved to the arcade VMs on stella
  # (2026-08-18), so GDM, GNOME, Steam, PipeWire and the Remote Play firewall
  # ports were all removed, along with the autologin/getty workarounds and the
  # GNOME-pulls-NetworkManager mkForce. The nvidia DRIVER above stays — Ollama's
  # CUDA and k3s GPU workloads need it; a desktop does not.
  #
  # Sleep stays masked at the systemd level regardless: a server must never
  # suspend. bob suspended at 19:01 on 2026-07-25 (GNOME idle-suspend, since
  # gone), taking k3s and the worker3 guest down with it and looking exactly
  # like a hard power-off from the network — a WoL magic packet resumed it.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Ollama, moved here from stella on 2026-08-17 ahead of stella's
  # Windows→NixOS conversion. Home Assistant's voice pipeline talks to this,
  # so it has to be serving HERE before stella is wiped, not after. bob
  # already carries the CUDA stack for the three 3060s, so this is a service
  # declaration rather than a driver project.
  #
  # Bound to 0.0.0.0 to match what stella exposed (the HA integration and
  # the ha-ollama watchdog both dial it over the LAN). The port is opened
  # below; note this list MERGES with the one in modules/k3s-agent.nix
  # rather than replacing it.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    host = "0.0.0.0";
    port = 11434;
    # ALL THREE CARDS, 36 GB, since 2026-09-15. No CUDA_VISIBLE_DEVICES pin.
    #
    # 17:00.0 spent three days reserved for the cluster, with the embeddings
    # pod as its consumer — a reservation with something actually running on
    # it, which was the whole point. What ended it is not a change of mind: the
    # cluster now has a real GPU node elsewhere. worker5 (a libvirt VM on
    # stella, CDI working, three cards of its own) took the mandate on
    # 2026-09-14, so holding a card here reserved the capacity twice.
    #
    # bge-m3 goes back into loadModels below rather than following the pod to
    # worker5, and that is the part worth explaining. The site embeds the
    # VISITOR'S QUESTION on every request — the published index is built
    # nightly, but comparing a question against it means vectorising the
    # question live. worker5 is drained and shut down by stella's game-mode
    # hook whenever an arcade guest starts, so serving /api/embed from there
    # would take the site's semantic search down for the length of a game. And
    # silently: /api/bob/health reports credential presence, not retrieval, so
    # the Kuma monitor would stay green while answers quietly lost their
    # excerpts. 664 MB next to a 20 GB model is the cheaper place for it.
    #
    # IF A SPLIT EVER COMES BACK, pin BY UUID, not by index — nvidia-smi orders
    # devices by PCI bus while CUDA defaults to fastest-first, so "0,1" can
    # mean different cards to the two tools, and any slot change reshuffles
    # indices anyway. Speed is not the reason either way: measured 2026-09-11,
    # 69.8-71.7 tok/s across three cards against 70.1-72.1 on two. What the
    # third card buys is headroom, not throughput.
    # One model, and both consumers share it: labodeludo.dev's "Parler à Bob"
    # (the sole tier since Bedrock was removed) and Home Assistant's voice
    # assistant. Carrying two meant 20 GB of the 24 GB across the two 3060s sat
    # occupied, because HA pins its model with keep_alive=-1.
    #
    # The CHAT model is deliberately absent from this list: qwen38-27b is
    # Qwen3.8-27B in Unsloth's UD-Q4_K_XL quantisation, and Ollama's Hugging
    # Face bridge refuses that tag outright ("not a valid quantization scheme")
    # — its bridge only accepts a closed list of standard quant names and the
    # UD-* family is not on it. So the GGUF is fetched directly and imported
    # with `ollama create`, by the unit below. Listing it here would make
    # ollama.service try to pull a tag that does not exist, on every boot.
    #
    # Only the pullable one; the chat model is imported by the unit below.
    # bge-m3 is back here since 2026-09-15 — see the card comment above for why
    # it did not follow the cluster's GPU mandate to worker5.
    loadModels = [ "bge-m3" ];
  };
  # Rebuild qwen38-27b when it is missing — after a reimage, or the first time
  # this config lands on a host that never had it.
  #
  # Why a unit rather than services.ollama.loadModels: that option pulls from a
  # registry, and this model is not in one — Ollama's Hugging Face bridge
  # refuses Unsloth's UD-* quantisations (see the comment above). So: fetch the
  # GGUF, write a one-line Modelfile, `ollama create`, and a reimaged bob
  # converges on the same model instead of silently serving nothing.
  #
  # 17.6 GB over the wire, so: guarded by a `ollama list` check, `curl -C -` to
  # resume a broken transfer, and no timeout (a slow night must not leave a
  # half-imported model behind). The scratch copy is removed on success —
  # `ollama create` copies the file into its own blob store.
  #
  # qwen38-27b (Qwen3.8-27B, DENSE, UD-Q4_K_XL) replaced qwen36-q4kxl
  # (Qwen3.6-35B-A3B) on 2026-09-26 for every caller: the site chat, Home
  # Assistant's voice assistant and ask-local.py's local sessions. Ludo's call,
  # for its judgement; the price is speed — 18 tok/s against 77, measured on
  # the three cards alone. All callers send num_ctx 16384 so Ollama keeps ONE
  # runner. The bench is in the bob-chat Worker's LOCAL_MODEL comment.
  #
  # Removing the old unit does not delete the old models: qwen36-q4kxl and
  # qwen35-q4kl stay in Ollama's store as rollbacks, until someone deletes
  # them on purpose.
  #
  # The copy on bob was imported by hand on 2026-09-13; its blob digest
  # (5440074c…) differs from what this URL serves today (3f227079…), so
  # Unsloth has re-uploaded the file since. A reimage would get the newer one.
  systemd.services.ollama-qwen38-27b = {
    description = "Import qwen38-27b (Unsloth UD-Q4_K_XL) into Ollama";
    after = [ "ollama.service" ];
    wants = [ "ollama.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.ollama ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "infinity";
      # The ollama CLI panics ("$HOME is not defined") before doing anything,
      # even `ollama list` against a remote server: it resolves the default
      # models dir at startup. System units have no HOME, so an empty runtime
      # dir is enough — the client writes nothing there (checked 2026-09-17).
      RuntimeDirectory = "ollama-qwen38-27b";
      Environment = [
        "OLLAMA_HOST=127.0.0.1:11434"
        "HOME=/run/ollama-qwen38-27b"
      ];
    };
    script = ''
      if ollama list | grep -q '^qwen38-27b:'; then
        echo "qwen38-27b already present"
        exit 0
      fi
      work=/var/tmp/qwen38-27b
      mkdir -p "$work"
      curl -sL -C - --retry 10 --retry-delay 5 \
        -o "$work/model.gguf" \
        https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_XL.gguf
      printf 'FROM %s/model.gguf\n' "$work" > "$work/Modelfile"
      ollama create qwen38-27b -f "$work/Modelfile"
      rm -rf "$work"
    '';
  };

  # Load the model into VRAM every time ollama.service starts.
  #
  # keep_alive -1 pins a model that is already loaded; it does not bring one
  # back. After any restart of ollama.service — a reboot, or a comin switch
  # that touches its unit — the GPUs sit empty until the first caller, and that
  # caller (a visitor on the site, or a voice question) pays ~30 s to read
  # 19 GB off the NVMe on top of the prompt. partOf + wantedBy tie this unit
  # to ollama.service, so it runs again on every restart, not only at boot.
  #
  # The options are the callers' own: the site chat, Home Assistant and
  # ask-local.py all send num_ctx 16384 and keep_alive -1. A load with any
  # other num_ctx would start a runner the first real request throws away.
  #
  # bge-m3 too (2026-09-26): pinned the same way, lost the same way. Its cold
  # load measured 2.2 s against the Worker's 3 s RETRIEVAL_TIMEOUT_MS, and the
  # tunnel adds its own share, so the first visitor after a restart could get
  # an answer without excerpts — with every monitor green.
  #
  # It does NOT warm Home Assistant's prompt cache: only HA can build its exact
  # prompt, and HA's 06:00 warm-up automation (bob_warmup_cache_vocal) does
  # that. After a restart here, the first voice question re-reads its prompt
  # once (~6 s on the 27B), then the cache holds.
  #
  # A failed load exits 0 with a message: a red unit turns the whole comin
  # deploy of bob red, and a cold model is a slow first answer, not an outage.
  #
  # NOT a two-slot setup: tried on 2026-09-26 (OLLAMA_NUM_PARALLEL=2, #96) so
  # HA and the chat would each keep a prompt cache, and it does nothing here —
  # Ollama 0.34 forces one slot for the qwen35 architecture ("model
  # architecture does not currently support parallel requests").
  systemd.services.ollama-warm-qwen38-27b = {
    description = "Load qwen38-27b and bge-m3 into VRAM after ollama starts";
    after = [ "ollama.service" "ollama-qwen38-27b.service" ];
    partOf = [ "ollama.service" ];
    wantedBy = [ "ollama.service" ];
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "10min";
    };
    script = ''
      for i in $(seq 1 60); do
        curl -sf -o /dev/null http://127.0.0.1:11434/api/version && break
        sleep 2
      done
      if curl -sf -o /dev/null --max-time 540 http://127.0.0.1:11434/api/generate \
          -d '{"model":"qwen38-27b","keep_alive":-1,"options":{"num_ctx":16384}}'; then
        echo "qwen38-27b loaded"
      else
        echo "WARNING: could not load qwen38-27b; the first caller will pay the cold load"
      fi
      # Same body as the Worker's embed call (model, input, keep_alive -1, no
      # options), so the runner it starts is the one the site reuses.
      if curl -sf -o /dev/null --max-time 120 http://127.0.0.1:11434/api/embed \
          -d '{"model":"bge-m3","input":["warm-up"],"keep_alive":-1}'; then
        echo "bge-m3 loaded"
      else
        echo "WARNING: could not load bge-m3; the first site question may lose its excerpts"
      fi
    '';
  };

  # 11434 = ollama, dialled over the LAN by Home Assistant's voice pipeline, by
  # labodeludo.dev's build when it re-embeds the corpus, and — through the
  # tunnel rather than here — by the bob-chat Worker.
  #
  # 10300 is GONE with the Wyoming speech-to-text pod it existed for. Kept in
  # history because the lesson outlives the port: a hostNetwork pod's ports are
  # NOT covered by the k3s-agent module's trustedInterfaces, which is the exact
  # trap that made frigate.lab.example hang after its k3s migration.
  networking.firewall.allowedTCPPorts = [ 11434 10200 ];

  # 10200 = Piper (Wyoming), Bob's VOICE in the dining room since 2026-10-02 —
  # « pierre » (fr_FR-upmc-medium, speaker 1), chosen by ear against
  # Zubenelgenubi. Why it replaced Google there: HA's Google Cloud TTS cannot
  # take text as a stream, so the voice waited for Bob's WHOLE answer and then
  # ~2.2 s more for Google (measured on the 2026-10-01 weather answer, 178
  # chars). Wyoming takes the text sentence by sentence, and Piper renders a
  # sentence in ~0.25 s on this CPU: Bob starts talking after his first
  # sentence. CPU only — the GPUs stay with ollama. Open to the LAN like 11434:
  # Wyoming has no auth, and all it can do is speak.
  services.wyoming.piper.servers.bob = {
    enable = true;
    voice = "fr_FR-upmc-medium";
    speaker = 1;            # pierre (0 = jessica)
    uri = "tcp://0.0.0.0:10200";
  };

  # Ollama probes for GPUs exactly once at startup, not per-request. With
  # only the default `After=network.target`, ollama.service can win a race
  # against the nvidia stack on boot, find no CUDA device, and silently fall
  # back to CPU inference for its whole runtime — a temperature query goes
  # from ~10s to minutes, with nothing in its logs pointing at the cause.
  # Found 2026-09-02: it raced a reboot done for unrelated RAM maintenance.
  # nvidia-container-toolkit-cdi-generator.service already `udevadm settle`s
  # on the nvidia devices before it runs, so anchor ollama to it instead of
  # re-deriving that wait.
  systemd.services.ollama = {
    after = [ "nvidia-container-toolkit-cdi-generator.service" ];
    wants = [ "nvidia-container-toolkit-cdi-generator.service" ];
  };

  environment.systemPackages = with pkgs; [ virt-manager pciutils ];

  ## --- Ubuntu-era backup volume (adopted 2026-09-16) ----------------------
  ##
  ## The three SATA SSDs (224+447+224 GB) survived the NixOS reinstall as
  ## LVM `backup-vg/backup-lv`, 894 GB ext4: the Timeshift snapshots of the
  ## Ubuntu bob (Apr-Jun 2025 - system only, /home and docker were excluded)
  ## and the Blu-ray scratch dirs `2d_temp`, `3d_temp`, `BD3D2MK3D`. Same
  ## shape as vega's and encodeur's backup-vg. Plain LVM, default udev
  ## activation; `nofail` so a dead SSD never keeps the GPU host from booting.
  fileSystems."/mnt/backup" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=30s" ];
  };

  system.stateVersion = "26.05";
}
