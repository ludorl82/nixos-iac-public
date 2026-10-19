## The two things this fleet pins BY HAND, kept in one file so they are bumped
## together: one PR, one deploy, one reboot window, one weekly nag.
##
## Everything else rides flake.lock. These two cannot:
##
##  * k3s — nixpkgs' k3s_1_36 stopped at 1.36.2 while upstream moved on, so
##    modules/k3s-upstream.nix fetches upstream's static binary instead.
##
##  * the NVIDIA driver (bob, encodeur, stella's host for its RTX 3050 since
##    2026-10-08, arcade1 and arcade2 for their Turing cards) — following
##    nvidiaPackages.production meant every nixpkgs promotion that moved the
##    driver swapped the userspace under a kernel module that stays loaded until
##    reboot. NVENC refused to open, nvidia-smi said "Driver/library version
##    mismatch", the CDI generator failed every switch, and anything GPU that
##    started afterwards failed while what was already running carried on:
##    2026-09-23 (bob), 2026-09-26 (encodeur's low-res archive), 2026-09-30
##    (encodeur, stella, bob). A kernel bump does NOT cause this — the module is
##    rebuilt at the same version — only a driver VERSION change does, so
##    pinning the version is enough. A pre-Turing card (the GTX 960 arcade2 had
##    until 2026-10-08) needs legacy_580 instead and would leave the pin.
##
## Bumping, once scripts/jumphost/weekly-updates.sh says either is behind:
##
##  1. k3s: set `version`, then paste the output of
##       nix-prefetch-url https://github.com/k3s-io/k3s/releases/download/v<ver>%2Bk3s1/k3s
##       nix-prefetch-url https://github.com/k3s-io/k3s/releases/download/v<ver>%2Bk3s1/k3s-arm64
##  2. NVIDIA: copy the five fields of `production = generic { ... }` from
##     pkgs/os-specific/linux/nvidia-x11/default.nix at the nixpkgs revision in
##     flake.lock (the nag names it). Copying them verbatim is what keeps the
##     derivation identical to nixpkgs' own, cache hits included.
##  3. One PR. Before merging, deploy aws by hand — it is the sole k3s server and
##     must lead (see modules/k3s-upstream.nix's history). Then merge; comin
##     rolls the agents.
##  4. Reboot the GPU hosts so the loaded module matches the new userspace:
##     encodeur, stella (its arcades with it), then bob LAST (its reboot suspends coquille, the console).
##     arcade1 reboots TWICE if it was off during the deploy: it boots its old
##     generation, comin switches it, and only the second boot loads the new
##     module (seen 2026-10-04). Until they reboot, a running GPU process is
##     fine and a new one is not.
{
  k3s = {
    version = "1.36.3+k3s1";
    sha256 = {
      x86_64-linux = "1dbnxmpdqll4179qxlz8rba6yzqan6hp0knmwag4g0jpzvwak61g";
      aarch64-linux = "1a4ics40vdvbf6ijkp44n8kijj5lc84g0mkaghxic3s87w80k8n9";
    };
  };

  nvidia = {
    version = "595.104.02";
    sha256_64bit = "sha256-5CHCAuTHn1jDx/MWG75xRU67PYiTb4ggWg4yfNBMWco=";
    sha256_aarch64 = "sha256-PafStmwNMufeDp3VtpTGGCoW+53Gor/mieO1m1pI7gI=";
    openSha256 = "sha256-FWk5ra2yjz8VAxAA8GXrSoeBj/XC1BKvsKsBKR09joE=";
    settingsSha256 = "sha256-4Kxro6tvI5aX4nu2RspgyBsW+Jq3/VYjSAS5UGdzTCU=";
    persistencedSha256 = "sha256-JsMLPqJuZwAtHngsQODMsmgO7F2tVkQ2arc7fYa2bwo=";
  };
}
