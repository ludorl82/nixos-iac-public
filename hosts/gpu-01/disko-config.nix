## OS disk only - gpu-01's 931G Example NVMe (currently /boot/efi + /boot +
## ubuntu-vg root). gpu-01's three SATA SSDs (sda/sdb/sdc - old
## frigate-vg/backup/loki data) are NOT listed here, so disko never
## touches them; only the NVMe OS disk is wiped.
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-EXAMPLE_NVME_0000000000000001";
        content = {
          type = "gpt";
          partitions = {
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
