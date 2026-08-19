## cloud-01 EC2 instance - single 64G EBS root volume, shows up as nvme0n1 on
## Nitro. No stable by-id serial worth pinning here (EBS volume IDs do
## appear under /dev/disk/by-id but the instance has exactly one disk, so
## /dev/nvme0n1 is unambiguous).
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
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
