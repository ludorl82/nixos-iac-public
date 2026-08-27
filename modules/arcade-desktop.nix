## Shared desktop stack for the arcade gaming VMs (arcade1/arcade2).
##
## KDE Plasma 6 (Wayland), NOT GNOME — deliberately. Steam Remote Play on a
## Wayland host captures through the xdg-desktop-portal RemoteDesktop portal,
## and GNOME's portal re-asks "Allow remote interaction?" on EVERY session
## start with no way to persist the grant (open upstream request,
## xdg-desktop-portal-gnome#175). Until someone clicked Allow over VNC the
## stream was "Desktop Black Frame". Plasma 6.3+ has a pre-authorization
## table (`kde-authorized`) in the portal permission store, so the prompt can
## be suppressed declaratively and streaming works from cold boot, unattended.
##
## The host config still sets: services.displayManager.autoLogin.user,
## users, networking, GPU. Everything session-shaped lives here.
{ pkgs, ... }:
{
  # --- Plasma 6 (Wayland), SDDM autologin -----------------------------------
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = "plasma";
  services.displayManager.autoLogin.enable = true;   # user set per-host

  # --- Locale ---------------------------------------------------------------
  # These are the only fleet hosts a PERSON looks at directly (Plasma panel
  # clock, Steam's library/playtime, game save timestamps), so they must show
  # wall-clock local time, not the UTC every headless node runs. Matches
  # gpu-02, the other host with a human-facing surface.
  time.timeZone = "America/Toronto";

  # --- Steam + Remote Play --------------------------------------------------
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
  };

  # Pre-authorize the (empty) host app-id for the RemoteDesktop portal so
  # Steam's capture starts with no dialog. Non-sandboxed apps resolve to the
  # empty app_id ("" = any host app — acceptable on a single-purpose gaming
  # VM). Equivalent of: flatpak permission-set kde-authorized remote-desktop "" yes
  # done via the PermissionStore D-Bus API (no flatpak CLI on the box).
  # Idempotent; runs at every graphical login.
  systemd.user.services.steam-portal-preauth = {
    description = "Pre-authorize Steam for the KDE remote-desktop portal";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.systemd}/bin/busctl --user call \
        org.freedesktop.impl.portal.PermissionStore \
        /org/freedesktop/impl/portal/PermissionStore \
        org.freedesktop.impl.portal.PermissionStore \
        SetPermission sbssas kde-authorized true remote-desktop "" 1 yes
    '';
  };

  # --- Never lock / blank / idle / sleep ------------------------------------
  # Headless streaming host: Remote Play can only stream a live, unlocked
  # session. [$i] marks the groups immutable so per-user settings can't
  # re-enable locking.
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon][$i]
    Autolock=false
    LockOnResume=false
  '';
  environment.etc."xdg/powerdevilrc".text = ''
    [AC][Display][$i]
    DimDisplayWhenIdle=false
    TurnOffDisplayWhenIdle=false

    [AC][SuspendAndShutdown][$i]
    AutoSuspendAction=0
    PowerButtonAction=0
  '';

  # Belt-and-braces at the systemd layer.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Auto-start Steam in the session so the Remote Play host is always up the
  # moment the VM boots. `-silent` starts it minimised to the tray. (The
  # one-time Steam *account* login is still manual, over VNC; it persists.)
  environment.etc."xdg/autostart/steam.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Steam
    Exec=steam -silent
    NoDisplay=true
  '';
}
