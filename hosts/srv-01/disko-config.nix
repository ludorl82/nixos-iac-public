## OS disk only - the Example 480G SSD that currently holds Ubuntu's
## /boot/efi + /boot + ubuntu-vg/ubuntu-lv (root). Every other disk on
## srv-01 (the WD 3-8TB drives making up the md0 RAID5 + data-EXAMPLE_SSD_0000000000000001 media
## array, and the backup-vg on a separate Example SSD) is untouched by
## this config - disko only ever formats what's listed here.
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/disk/by-id/ata-EXAMPLE_SSD_0000000000000001";
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
