# Caps Lock is a Ctrl key on the console of the X11SRA hosts.
#
# WHY (2026-10-09). Ludo asked for it on bob, stella, vega and encodeur:
# the same hand position for Ctrl on the VGA console, through the BMC's iKVM
# (its virtual USB keyboard goes through the same kernel keymap) and on the
# rack kiosk, which reads this option for Wayfire and sway (modules/kiosk.nix).
#
# console.useXkbConfig turns the xkb layout and options into the virtual
# console's keymap (ckbcomp); no X server is enabled by setting them.
{ ... }:

{
  services.xserver.xkb.options = "ctrl:nocaps";
  console.useXkbConfig = true;
}
