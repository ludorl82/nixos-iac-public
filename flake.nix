{
  description = "NixOS host configs for the homelab bare-metal fleet, installed via nixos-anywhere";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # pi-01/pi-02 are Pi 5s - that hardware doesn't use disko at all,
    # see hosts/pi-02/configuration.nix for why.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
    # Provides the kexec-installer module we extend into a custom, VLAN-aware
    # kexec image (see hosts/srv-01/kexec-network.nix for why the stock
    # one can't be used on a VLAN-tagged host).
    nixos-images.url = "github:nix-community/nixos-images";
    # GitOps deployment: each enrolled host polls this repo's master branch,
    # builds its own config and switches (see modules/comin.nix). Pinned to a
    # release tag; bump deliberately.
    comin = {
      url = "github:nlewo/comin/v0.14.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, nixos-raspberrypi, nixos-images, comin }@inputs:
    let
      # The one module every host in the fleet gets. Stamps each host with the
      # git revision that built it and wires in the driftcheck user
      # (modules/drift-check.nix); self.rev is unset when the tree is dirty --
      # the nightly drift check will rightly flag such builds. Also carries the
      # nix daemon settings that let deploys be pushed between hosts
      # (modules/nix-settings.nix).
      commonModule = {
        imports = [
          ./modules/drift-check.nix
          ./modules/nix-settings.nix
        ];
        system.configurationRevision = self.rev or "dirty";
      };
    in {
    nixosConfigurations.srv-01 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        commonModule
        disko.nixosModules.disko
        comin.nixosModules.comin
        ./modules/comin.nix
        ./hosts/srv-01/disko-config.nix
        ./hosts/srv-01/configuration.nix
      ];
    };

    nixosConfigurations.gpu-02 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        commonModule
        disko.nixosModules.disko
        comin.nixosModules.comin
        ./modules/comin.nix
        ./hosts/gpu-02/disko-config.nix
        ./hosts/gpu-02/configuration.nix
      ];
    };

    # cloud-01 is the EC2 instance - sole k3s control-plane/etcd + WireGuard hub
    # + the KeePass/Kuma/ntfy docker stacks. Converted in place with the
    # STOCK kexec (single DHCP ENI, no VLANs - none of the custom kexec
    # machinery the homelab hosts needed); state restored via --extra-files.
    #
    # Enrolled in comin LAST (2026-07-30, its own commit, etcd snapshot
    # pre-comin-20260730 taken first): it is the sole control-plane, so a bad
    # unattended deploy here takes the host that would have fixed it.
    # Recovery: EC2 serial console + boot the previous generation. It also
    # gets build-limits.nix — on a 4 GB t3a.medium carrying etcd, a build
    # must lose to the control plane, never the reverse.
    nixosConfigurations.cloud-01 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        commonModule
        disko.nixosModules.disko
        comin.nixosModules.comin
        ./modules/comin.nix
        ./modules/build-limits.nix
        ./hosts/cloud-01/disko-config.nix
        ./hosts/cloud-01/configuration.nix
      ];
    };

    nixosConfigurations.gpu-01 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        commonModule
        disko.nixosModules.disko
        comin.nixosModules.comin
        ./modules/comin.nix
        ./hosts/gpu-01/disko-config.nix
        ./hosts/gpu-01/configuration.nix
      ];
    };

    # vm-02 is a libvirt VM on srv-01 (macvtap on vlan10). Plain
    # x86_64 + disko on the virtio /dev/vda; guest is untagged on VLAN10.
    nixosConfigurations.vm-02 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        commonModule
        disko.nixosModules.disko
        comin.nixosModules.comin
        ./modules/comin.nix
        ./hosts/vm-02/disko-config.nix
        ./hosts/vm-02/configuration.nix
      ];
    };

    # vm-01 is a libvirt VM on gpu-01 (macvtap on vlan10), same as vm-02.
    # It was the comin canary (2026-07-30, pre-enrollment snapshot on gpu-01);
    # the rest of the home fleet followed the same day.
    nixosConfigurations.vm-01 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        commonModule
        disko.nixosModules.disko
        comin.nixosModules.comin
        ./modules/comin.nix
        ./hosts/vm-01/disko-config.nix
        ./hosts/vm-01/configuration.nix
      ];
    };

    # console-vm: the console VM on gpu-01 (jumphost/console split 2026-08-07) —
    # same libvirt/macvtap shape as vm-01, but NOT a k3s agent: it is the
    # interactive admin workspace, moved off the 4 GiB pi-02 Pi.
    nixosConfigurations.console-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        commonModule
        disko.nixosModules.disko
        comin.nixosModules.comin
        ./modules/comin.nix
        ./hosts/console-vm/disko-config.nix
        ./hosts/console-vm/configuration.nix
      ];
    };

    # vm-03 is a Hyper-V VM on `hyperv-host` - plain x86_64 + disko, no VLAN
    # tagging in the guest (Hyper-V presents two already-untagged vswitch
    # NICs), so the stock kexec installer is fine here and no custom
    # kexec/installer image is needed the way srv-01 required one.
    nixosConfigurations.vm-03 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        commonModule
        disko.nixosModules.disko
        comin.nixosModules.comin
        ./modules/comin.nix
        ./hosts/vm-03/disko-config.nix
        ./hosts/vm-03/configuration.nix
      ];
    };

    # pi-01 (Pi5) bootable image via nvmd's own image builder - the same
    # mechanism behind installerImages.rpi5 that we proved boots on pi-02.
    # For a Pi the flashed image IS the running system (there's no separate
    # install-to-disk step), so this bakes pi-01's config into a bootable
    # image. It carries some installer conveniences (console autologin,
    # first-boot partition expand); once pi-01 is up + reachable over SSH
    # we can nixos-rebuild it to the plain config to shed those. sdImage at
    # nixosConfigurations.pi-01.config.system.build.sdImage.
    nixosConfigurations.pi-01 = nixos-raspberrypi.lib.nixosInstaller {
      specialArgs = inputs;
      modules = [
        commonModule
        nixos-raspberrypi.inputs.nixos-images.nixosModules.sdimage-installer
        ({ config, lib, modulesPath, ... }: {
          disabledModules = [ (modulesPath + "/installer/sd-card/sd-image-aarch64-installer.nix") ];
          image.baseName = lib.mkOverride 40 "pi-01-rpi5";
        })
        comin.nixosModules.comin
        ./modules/comin.nix
        ./modules/build-limits.nix
        ./hosts/pi-01/configuration.nix
      ];
    };

    nixosConfigurations.pi-02 = nixos-raspberrypi.lib.nixosInstaller {
      specialArgs = inputs;
      modules = [
        commonModule
        nixos-raspberrypi.inputs.nixos-images.nixosModules.sdimage-installer
        ({ config, lib, modulesPath, ... }: {
          disabledModules = [ (modulesPath + "/installer/sd-card/sd-image-aarch64-installer.nix") ];
          image.baseName = lib.mkOverride 40 "pi-02-rpi5";
        })
        comin.nixosModules.comin
        ./modules/comin.nix
        ./modules/build-limits.nix
        ./hosts/pi-02/configuration.nix
      ];
    };

    # "docker" (ex-console-vm Pi 4): registry host on MAINLINE aarch64 NixOS
    # (generic cached kernel — the nvmd vendor stack is a Pi 5 need only).
    # No comin (2 GB cannot eval the flake; deploys pushed from gpu-01).
    # sdImage at nixosConfigurations.docker.config.system.build.sdImage —
    # build on gpu-01 (aarch64 via binfmt).
    nixosConfigurations.docker = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        commonModule
        "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
        ./hosts/docker/configuration.nix
      ];
    };

    # Custom VLAN10-aware kexec installer tarball for srv-01, consumed by
    # nixos-anywhere via --kexec so the installer stage comes up on the same
    # 192.0.2.97 address as the running system (stock one lands on the
    # untagged native VLAN instead).
    packages.x86_64-linux.kexec-srv-01 =
      (nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-images.nixosModules.kexec-installer
          nixos-images.nixosModules.noninteractive
          ./hosts/srv-01/kexec-network.nix
        ];
      }).config.system.build.kexecInstallerTarball;

    # VLAN10-aware kexec image for gpu-01 (parent eno2) - lets gpu-01 be converted
    # entirely over SSH (it's a running host): nixos-anywhere --kexec keeps
    # it at 192.0.2.129 through the kexec, no USB/monitor needed.
    packages.x86_64-linux.kexec-gpu-01 =
      (nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-images.nixosModules.kexec-installer
          nixos-images.nixosModules.noninteractive
          ./hosts/gpu-01/kexec-network.nix
        ];
      }).config.system.build.kexecInstallerTarball;

    # Bootable x86_64 installer ISO for srv-01 recovery: comes up
    # headless on DHCP (native VLAN) with our SSH keys, reachable so we can
    # re-run the install with proper hardware detection. Flashed to USB.
    packages.x86_64-linux.installer-srv-01 =
      (nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-images.nixosModules.image-installer
          ./hosts/srv-01/installer.nix
        ];
      }).config.system.build.isoImage;

    # Static-IP installer ISO for the vm-02 VM (VLAN10 has no DHCP).
    packages.x86_64-linux.installer-vm-02 =
      (nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-images.nixosModules.image-installer
          ./hosts/vm-02/installer.nix
        ];
      }).config.system.build.isoImage;

    packages.x86_64-linux.installer-vm-01 =
      (nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-images.nixosModules.image-installer
          ./hosts/vm-01/installer.nix
        ];
      }).config.system.build.isoImage;

    packages.x86_64-linux.installer-console-vm =
      (nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-images.nixosModules.image-installer
          ./hosts/console-vm/installer.nix
        ];
      }).config.system.build.isoImage;
  };
}
