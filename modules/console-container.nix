# The console container — the interactive workspace (Claude Code, repos,
# nested docker builds). Two importers with opposite postures:
#   - console-vm (VM on gpu-01):  autoStart = true, the real console
#   - pi-02 (jumphost):     autoStart = false — the EMERGENCY console,
#     image resident on disk, `systemctl start docker-console` during an
#     outage; pi-02 is the survivor-island host so this is the shell
#     that outlives a house power event.
#
# Out-of-band seeds: /var/lib/console/env (PASS=<console user password>),
# and the home directory itself (S3 tarball + git clones — see
# scripts/seed-console-home.sh).
{ config, pkgs, lib, ... }:
let
  cfg = config.homelab.console;
in
{
  options.homelab.console = {
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the console container at boot. False = emergency posture: unit declared, image kept resident, started by hand.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.str;
      default = "2g";
      description = "docker --memory for the container.";
    };
    memorySwap = lib.mkOption {
      type = lib.types.str;
      default = "3g";
      description = "docker --memory-swap for the container.";
    };
    image = lib.mkOption {
      type = lib.types.str;
      # The 2026-08-05 arm64 build — pi-02's pin. Overridden per-host so a
      # new digest doesn't restart every console at once (a switch that
      # changes the container definition kills the session running inside).
      default = "docker.lab.example:5000/console-personal@sha256:6b0f662686f5941fc6263cb0509e1d55327a67fc78f3d1203d2dcad102fabdee";
      description = "Console image reference (digest-pinned, see comments below).";
    };
    stableHostKeys = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Bind-mount /var/lib/console/ssh at /etc/ssh/keys so the container's sshd identity survives image rebuilds (needs an image with the console-entry.sh shim, 2026-08-07+).";
    };
  };

  config = {
    virtualisation.docker.enable = true;
    users.users.ludorl82.extraGroups = [ "docker" ];

    # Whole-home bind mount, sshd on :2222, docker socket for nested
    # tooling — identical contract to console-vm-the-Pi4's compose.
    virtualisation.oci-containers.backend = "docker";
    virtualisation.oci-containers.containers.console = {
      # Pulled from the fleet registry (TLS, CA via private-ca.nix) since
      # 2026-08-05 — replaces the hand docker-save/load flow. Runtime never
      # touches the registry: the unit runs `docker run --pull missing`, so
      # the console starts from the local store with the registry/NAS dark
      # (survivor-island requirement). Keep the old
      # `ludorl82/console-personal:latest` local tag as a rollback — same
      # image, don't "clean it up".
      #
      # PINNED BY DIGEST, deliberately. With a `:latest` tag, `--pull missing`
      # would never notice a newer push — the local copy always satisfies it,
      # so the console would run a stale image forever. A digest makes the
      # version explicit in git and turns a new build into a genuinely
      # "missing" image that gets pulled exactly once.
      #
      # Rebuild flow: net-cfgs/console-image-build.md. Nothing automates it,
      # and it ends with a commit updating the digest below. Build the arm64
      # half NATIVELY on a Pi — gpu-01 cannot build arm64 (its binfmt handler is
      # P-flag, not F, so emulated RUN steps die; it would silently emit an
      # amd64 image). The amd64 half builds natively on gpu-01.
      #
      # Previous: sha256:864d8920839aa6e64a7c584cd02ddef101092561c5ab27c76cb063657bda4d26
      # (built 2026-07-25). To roll back, put that digest back here — but note
      # it now pulls from the REGISTRY: a push reassigns the local repo-digest,
      # so the old digest under this repo path no longer resolves offline, and
      # it survives only until registry GC. The offline-safe rollback is the
      # legacy local tag, same image:
      #   ludorl82/console-personal@sha256:864d8920839aa6e64a7c584cd02ddef101092561c5ab27c76cb063657bda4d26
      image = cfg.image;
      ports = [ "2222:22" ];
      volumes = [
        "/home/ludorl82:/home/ludorl82"
        "/var/run/docker.sock:/var/run/docker-host.sock"
      ] ++ lib.optional cfg.stableHostKeys "/var/lib/console/ssh:/etc/ssh/keys:ro";
      environmentFiles = [ "/var/lib/console/env" ];
      extraOptions = [ "--memory=${cfg.memoryLimit}" "--memory-swap=${cfg.memorySwap}" ];
    };

    # Emergency posture: the unit exists (and pulls/keeps the image via its
    # normal preStart when started), but nothing wants it at boot.
    systemd.services.docker-console.wantedBy = lib.mkIf (!cfg.autoStart) (lib.mkForce [ ]);

    # The container's sshd reads ~/.ssh/authorized_keys from the bind-mounted
    # home — a DIFFERENT file from the host sshd's declarative
    # /etc/ssh/authorized_keys.d/ludorl82, and until 2026-08-07 it was
    # imperative, in no repo (the P6 gap). It cannot be a symlink into
    # /etc or /nix/store: neither path exists inside the container. And it
    # cannot be a tmpfiles "C+" copy: on this systemd C+ silently refuses to
    # overwrite an existing file (verified live 2026-08-07). So an activation
    # script installs the host's own merged declared key set on every
    # switch/boot — on pi-02 that is the jumphost service keys + laptop, on
    # console-vm just the console's callers. Ad-hoc key additions no longer
    # survive a switch; declare them in the host config instead.
    systemd.tmpfiles.rules = [
      "d /home/ludorl82/.ssh 0700 ludorl82 users -"
    ];
    system.activationScripts.consoleAuthorizedKeys =
      let
        keysFile = pkgs.writeText "console-authorized-keys"
          (lib.concatStringsSep "\n" config.users.users.ludorl82.openssh.authorizedKeys.keys + "\n");
      in ''
        install -D -m 0600 -o ludorl82 -g users ${keysFile} /home/ludorl82/.ssh/authorized_keys
      '';
  };
}
