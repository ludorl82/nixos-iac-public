## arcade1 is a libvirt VM on gaming-01 — single virtio disk /dev/vda, backed by
## /var/lib/libvirt/images/arcade1.qcow2. Same GPT/ESP/ext4 shape as vm-02.
## Steam libraries live on / (the qcow2 is sized generously in
## libvirt-domain.xml), so no separate games partition here.
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/vda";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
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
