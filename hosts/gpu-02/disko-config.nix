## OS disk only - the Example 480G SSD that currently holds Ubuntu's
## /boot/efi + /boot + ubuntu-vg/ubuntu-lv (root). gpu-02's other disks
## (the backup-vg and backup-vg-frigate LVM volumes across the other
## Example SSDs) are untouched by this config - disko only formats what's
## listed here. Frigate itself already moved to gpu-01 in an earlier session,
## so nothing here is load-bearing, but the frigate LVM data still lives on
## those other disks and is deliberately left intact.
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
