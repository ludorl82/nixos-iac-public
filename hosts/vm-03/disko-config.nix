## vm-03 is a Hyper-V VM on `hyperv-host` with a single 40G virtual disk -
## there is nothing else on the box to preserve, so this config owns the
## whole disk. Layout mirrors what Debian had (976M ESP / root / 2G swap),
## keeping the swap partition because the VM only has 3.8G of RAM and
## dropping it would be a regression.
##
## The by-id path is the SCSI WWN that storvsc exposes for the virtual
## disk; it is stable across boots and identical under the kexec installer
## (verified before running disko).
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x0000000000000001";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            swap = {
              size = "2G";
              content = {
                type = "swap";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
