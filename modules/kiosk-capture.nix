# labo.kioskCapture — USB HDMI capture cards served to the rack kiosk.
#
# WHY (2026-10-14). The kiosk moved from stella to its own machine (kiosque),
# but the two UGREEN cards that capture the work laptop's two screens stay
# plugged into stella: their cables do not reach kiosque. So the cards are
# served where they are plugged, and the kiosk reaches them through an SSH
# tunnel.
#
# NOTHING LEAVES THE HOST IN CLEAR. Each card is one ustreamer on 127.0.0.1
# only, as when the kiosk ran on the same host (modules/kiosk.nix uses this
# module for its own cards). A remote kiosk forwards those ports over SSH as
# `kiosk-tunnel`, a user with no shell whose key may open these ports and
# nothing else (restrict + permitopen). The work laptop's screen never crosses
# the network unencrypted, and no other host can reach the streams.
{ config, lib, pkgs, ... }:
let
  cfg = config.labo.kioskCapture;
in
{
  options.labo.kioskCapture = {
    cards = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption { type = lib.types.strMatching "[a-z0-9-]+"; };
          port = lib.mkOption {
            type = lib.types.port;
            description = "ustreamer's port on 127.0.0.1: 8100 + the kiosk desktop's numpad key.";
          };
          device = lib.mkOption {
            type = lib.types.str;
            example = "/dev/v4l/by-path/pci-0000:00:14.0-usb-0:6:1.0-video-index0";
            description = "The card's V4L2 device. by-path when two cards share a serial.";
          };
        };
      });
      default = [ ];
    };
    clientKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Public keys of the kiosks allowed to forward the cards' ports (user kiosk-tunnel).";
    };
  };

  config = lib.mkMerge [
    {
      systemd.services = lib.listToAttrs (map (c: lib.nameValuePair "kiosk-capture-${c.name}" {
        description = "Capture card '${c.name}' for the rack kiosk (127.0.0.1:${toString c.port})";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.ustreamer}/bin/ustreamer"
            # 60 fps and only two device buffers: ustreamer always serves the
            # newest frame. Tried against mpv reading the card directly
            # (2026-10-09, #169, reverted): Ludo found ustreamer's latency
            # better, even with mpv's low-latency profile, CPU decode and no
            # vsync.
            "--device=${c.device}" "--format=MJPEG" "--resolution=1920x1080" "--desired-fps=60"
            "--buffers=2"
            "--host=127.0.0.1" "--port=${toString c.port}"
            "--persistent"
          ];
          DynamicUser = true;
          SupplementaryGroups = [ "video" ];
          Restart = "always";
          RestartSec = 5;
        };
      }) cfg.cards);
    }
    (lib.mkIf (cfg.clientKeys != [ ]) {
      users.groups.kiosk-tunnel = { };
      users.users.kiosk-tunnel = {
        isSystemUser = true;
        group = "kiosk-tunnel";
        # sshd still wants an executable shell to accept the login; the key's
        # `restrict` and the client's -N mean it never runs.
        shell = "${pkgs.shadow}/bin/nologin";
        openssh.authorizedKeys.keys = map (k:
          lib.concatStringsSep "," ([ "restrict" "port-forwarding" ]
            ++ map (c: ''permitopen="127.0.0.1:${toString c.port}"'') cfg.cards)
          + " " + k) cfg.clientKeys;
      };
    })
  ];
}
