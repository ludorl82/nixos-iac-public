## The fleet's k3s, taken from upstream's static release binary.
##
## NOT a NixOS module — a package expression, `callPackage`d from the three
## places that set `services.k3s.package` (modules/k3s-agent.nix, hosts/aws,
## and hosts/worker1 + worker2 via the top-level nixpkgs instance). One
## definition so the fleet cannot skew: the server and every agent resolve
## to the same store path per architecture.
##
## Why not `pkgs.k3s_1_36`, which is where this repo deliberately moved on
## 2026-07-24 after deleting an earlier hand-rolled fetchurl: nixpkgs still
## packages 1.36.2+k3s1 at that attribute — checked on 2026-08-09 against the
## cp-1 lock, PR #7's lock, and nixpkgs-unstable HEAD, all three — while
## upstream stable moved to 1.36.3+k3s1. There is no k3s_1_37 either. So the
## attribute cannot express the version the cluster is supposed to run, and
## this file exists until it can.
##
## **Delete this and go back to `pkgs.k3s_1_36` the moment nixpkgs catches
## up.** The packaged attribute is better in every way that matters — it is
## reproducible from source, it is what the weekly flake update tracks, and
## it does not need a human to notice a release. This is a stopgap wearing
## the shape of the thing it replaces.
##
## The binary is fully static and self-extracts its userland into
## /var/lib/rancher/k3s/data, which is what makes it work on NixOS at all.
## The version and both hashes live in ../pins.nix since 2026-10-01, next to the
## NVIDIA driver's, so the two hand-pinned things are bumped together; the
## procedure is written there.
{ stdenv, fetchurl, lib }:

let
  pin = (import ../pins.nix).k3s;
  inherit (pin) version;
  # URL-encoded '+' — the release tag really does contain it
  tag = "v${lib.replaceStrings [ "+" ] [ "%2B" ] version}";
  # upstream ships one asset per architecture, named differently
  assets = {
    x86_64-linux = {
      name = "k3s";
      sha256 = pin.sha256.x86_64-linux;
    };
    aarch64-linux = {
      name = "k3s-arm64";
      sha256 = pin.sha256.aarch64-linux;
    };
  };
  system = stdenv.hostPlatform.system;
  asset = assets.${system} or (throw
    "k3s-upstream: no upstream release asset for ${system}");
in
stdenv.mkDerivation {
  pname = "k3s-upstream-bin";
  inherit version;

  src = fetchurl {
    url =
      "https://github.com/k3s-io/k3s/releases/download/${tag}/${asset.name}";
    inherit (asset) sha256;
  };

  dontUnpack = true;

  # k3s dispatches on argv[0]: the same binary is kubectl, crictl and ctr
  # depending on how it is called. The symlinks are not cosmetic — the
  # kubelet and the k3s unit both invoke them by those names.
  installPhase = ''
    mkdir -p $out/bin
    install -m 0755 $src $out/bin/k3s
    ln -s k3s $out/bin/kubectl
    ln -s k3s $out/bin/crictl
    ln -s k3s $out/bin/ctr
  '';

  meta = {
    description = "k3s ${version}, upstream static release binary";
    homepage = "https://github.com/k3s-io/k3s";
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
