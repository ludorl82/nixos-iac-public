## The whole 120 GB Example SSD (ata-...50026B7775015292, read from the
## installer on 2026-10-14). It carried an old LVM volume from the vega
## era; Ludo asked for it to be reformatted. The board has no other disk.
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
