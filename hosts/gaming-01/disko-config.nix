## OS disk only for gaming-01. GPT with a 1 M BIOS-boot partition + 1 G ESP +
## ext4 root — a superset of hosts/gpu-01/disko-config.nix.
##
## WHY THE bios_grub PARTITION (gpu-01 does NOT have one): gaming-01 is being
## converted while its firmware sits in LEGACY/CSM boot mode. Load Optimized
## Defaults (the change that stranded this host on 2026-08-17) flipped Boot
## Mode away from UEFI, and BIOS Setup is unreachable — the discrete GPU owns
## video and the AMI Setup UI does not render over SOL, so the mode cannot be
## switched back without a physical visit. The booted installer confirmed it:
## /sys/firmware/efi was absent, i.e. it came up in legacy mode.
##
## So the installed system must boot in EITHER firmware mode, because which
## mode the firmware is in cannot be seen or changed remotely. That means
## GRUB, not systemd-boot (see configuration.nix boot.loader), and GRUB's
## legacy path on a GPT disk needs this tiny EF02 partition to embed core.img.
## The ESP still carries the UEFI removable-path loader for the day the
## firmware is put back to UEFI. Belt and braces, same spirit as the
## installer's dual VLAN10/VLAN50 network path.
##
## !! THE DEVICE PATH — read off the booted installer 2026-08-17 !!
## nvme0n1 = Example SNVS500G, the sole NVMe. lsblk showed it carrying the
## Windows GPT (ESP + MSR + 464G NTFS + recovery) that this wipes. The two
## other drives gaming-01 turned out to have are SATA SSDs (sda/sdb, Example
## A400 240G) and are deliberately absent here, so disko never touches them —
## same reason gpu-01's SATA SSDs are absent from its config.
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-EXAMPLE_NVME_0000000000000001";
        content = {
          type = "gpt";
          partitions = {
            # Legacy GRUB core.img lands here (BIOS/CSM boot path). No
            # filesystem, no mountpoint — GRUB embeds into it directly.
            boot = {
              size = "1M";
              type = "EF02";
            };
            ESP = {
              size = "1G";
              type = "EF00";
              content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
            };
            root = {
              size = "100%";
              content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
            };
          };
        };
      };
    };
  };
}
