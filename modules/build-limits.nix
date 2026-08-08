# Build hygiene for the RAM-constrained comin hosts: the 4 GB Pi 5s
# (pi-01/2) and cloud-01 (4 GB t3a.medium, sole k3s control-plane — there a
# runaway build would starve etcd, which is strictly worse than a failed
# deploy). Learned on 2026-07-30 when the comin fleet bootstrap
# took both Pis to NotReady: they spent an hour compiling matplotlib from
# source — needed only by the TEST SUITE of markdown-it-py, needed by rich,
# needed by remarshal, needed to render comin's ten-line YAML config. The
# Pis build from the nvmd nixpkgs pin (older than the x86 fleet's), whose
# aarch64 paths partially age out of cache.nixos.org, so "tiny config tool"
# can silently become "compile a plotting library on 4 ARM cores".
#
# Two defenses, independent:
#
# 1. Cut the absurd edge: markdown-it-py with doCheck = false drops
#    pytest-regressions and with it the whole matplotlib subtree. The
#    override rebuilds the (pure-Python, minutes-cheap) remarshal chain and
#    nothing else — python3Packages users outside that chain are unaffected.
# 2. Assume some future source-build will still happen, and make it lose to
#    the node instead of winning: nix-daemon capped well below the Pi's 4 GB
#    (MemoryMax kills the build; kubelet and sshd keep breathing) and builds
#    serialized to one job on 3 of 4 cores. These are 4 GB Pi 5s — measured,
#    not assumed; the first version of this file capped at 4G/5G, which on a
#    4 GB machine is no cap at all.
{ lib, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
        (pyFinal: pyPrev: {
          markdown-it-py = pyPrev.markdown-it-py.overridePythonAttrs (_: {
            doCheck = false;
          });
        })
        # The same trap, walked into again on 2026-08-06 by the Gmail-filter
        # deps (modules/console-host.nix): the flake's nixpkgs pin is not a
        # channel revision, so hydra never built these and every one is an
        # aarch64 cache miss. The packages are pure Python and compile in
        # seconds; their test suites drag in django, aiohttp, geoip2 and —
        # via pytest-regressions — matplotlib again. comin started that build
        # on pi-02 and took the box to 255 MB free before it was stopped.
        #
        # Note the shape this keeps repeating in: a trivial dependency is
        # cheap, its TEST dependencies are not, and nothing in the config
        # hints at the difference until a 4 GB Pi starts running ninja.
        (pyFinal: pyPrev:
          lib.genAttrs [
            "google-auth"
            "google-auth-oauthlib"
            "google-auth-httplib2"
            "google-api-core"
            "google-api-python-client"
            "httplib2"
          ] (name: pyPrev.${name}.overridePythonAttrs (_: { doCheck = false; })))
      ];
    })
  ];

  nix.settings = {
    max-jobs = 1;
    cores = 3;
  };

  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "2G";
    MemoryMax = "2560M";
    OOMScoreAdjust = 500;
  };
}
