## The fleet's NVIDIA driver, at the version pinned in ../pins.nix.
##
## NOT a NixOS module — like ./k3s-upstream.nix, an expression the hosts call
## from `hardware.nvidia.package`, so every GPU host resolves to the same
## driver and cannot skew:
##
##   package = import ../../modules/nvidia-driver.nix {
##     inherit (config.boot.kernelPackages) nvidiaPackages;
##   };
##
## mkDriver is the same function nixpkgs builds its own branches with
## (`mkDriver = generic`), so the pinned fields copied from `production` give
## the same derivation as `nvidiaPackages.production` did. The kernel module
## still rebuilds against each new kernel; only the version stays put.
{ nvidiaPackages }:
nvidiaPackages.mkDriver (import ../pins.nix).nvidia
