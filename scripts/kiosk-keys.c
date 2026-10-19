/* kiosk-keys — the rack keyboard types into the kiosk, and only there.
 *
 * WHY (2026-10-10). Ludo wants to log into stella from its own face of the
 * cube, through its iKVM, instead of Ctrl+Alt+F2 on the console. But the
 * kernel's keyboard handler feeds EVERY keyboard to the active virtual
 * terminal, whatever its logind seat: a key typed on the rack reached
 * stella's console directly AND through the iKVM, twice; and keys typed on
 * any other face (bob's iKVM, the work laptop) would land in a shell left
 * open on stella's console. That is why tty1 showed the journal, read-only.
 *
 * So this takes every keyboard of the kiosk seat for itself (EVIOCGRAB: the
 * kernel's console and libinput get nothing from it any more) and replays its
 * keys into the compositor as a Wayland virtual keyboard
 * (zwp_virtual_keyboard_v1, offered by Wayfire and sway). A uinput device
 * would not do: the kernel's keyboard handler attaches to virtual devices
 * too.
 *
 *   kiosk-keys <glob> <exclude> <xkb-options>
 *
 * <glob>     the keyboards to take (udev links them as
 *            /dev/input/kiosk-key-*, modules/kiosk.nix); looked at again
 *            every two seconds, since the USB switch takes them away and back
 * <exclude>  a device left alone (the numpad: evsieve holds it)
 * <xkb-options> e.g. ctrl:nocaps
 *
 * Ctrl+Alt+F1..F10: Wayfire takes them as a VT switch by key code, whatever
 * the keymap, but only when Ctrl and Alt are the only modifiers down
 * (check_vt_switch, Wayfire 0.10.1; wlroots leaves locked modifiers out, so
 * Num Lock does not count). So while Ctrl and Alt are both down, this
 * keyboard also reports Mod3, which nothing in a us keymap uses, as latched:
 * the combination then reaches the iKVM, and stella's console changes
 * (2026-10-12; srvrkeys:none and a locked Num Lock did nothing).
 *
 * The keymap is us/pc105, the host's. Exits when the compositor goes away;
 * the grabs go with the process, and kiosk.nix restarts it.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

#define MAXDEV 32

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;
static struct {
  int fd;
  dev_t rdev;
  char path[256];
  unsigned char held[KEY_MAX / 8 + 1];  /* keys down on this device */
} devs[MAXDEV];
static int ndevs;

static void global(void *data, struct wl_registry *reg, uint32_t name,
                   const char *iface, uint32_t version) {
  (void)data; (void)version;
  if (!seat && strcmp(iface, wl_seat_interface.name) == 0)
    seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
  else if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0)
    manager = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void global_remove(void *data, struct wl_registry *reg, uint32_t name) {
  (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener registry_listener = { global, global_remove };

static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/* Take every keyboard matching the glob that is not taken yet. */
static void scan(const char *pattern, dev_t exclude) {
  glob_t g;
  if (glob(pattern, 0, NULL, &g) != 0) return;
  for (size_t i = 0; i < g.gl_pathc && ndevs < MAXDEV; i++) {
    struct stat st;
    if (stat(g.gl_pathv[i], &st) != 0 || st.st_rdev == exclude) continue;
    int known = 0;
    for (int j = 0; j < ndevs; j++) known |= devs[j].rdev == st.st_rdev;
    if (known) continue;
    int fd = open(g.gl_pathv[i], O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) continue;
    if (ioctl(fd, EVIOCGRAB, 1) != 0) { close(fd); continue; }  /* held by someone else */
    memset(&devs[ndevs], 0, sizeof devs[ndevs]);
    devs[ndevs].fd = fd;
    devs[ndevs].rdev = st.st_rdev;
    snprintf(devs[ndevs].path, sizeof devs[ndevs].path, "%s", g.gl_pathv[i]);
    fprintf(stderr, "kiosk-keys: took %s\n", devs[ndevs].path);
    ndevs++;
  }
  globfree(&g);
}

static struct zwp_virtual_keyboard_v1 *kbd;
static struct xkb_state *state;
static uint32_t mods[4];
static uint32_t mod3;  /* latched while Ctrl and Alt are down, see above */

/* One key to the compositor, with the modifiers it changes. */
static void key(int i, unsigned code, int down) {
  if (code > KEY_MAX) return;
  if (down) devs[i].held[code / 8] |= 1 << (code % 8);
  else devs[i].held[code / 8] &= ~(1 << (code % 8));
  xkb_state_update_key(state, code + 8, down ? XKB_KEY_DOWN : XKB_KEY_UP);
  zwp_virtual_keyboard_v1_key(kbd, now_ms(), code,
                              down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
  uint32_t m[4] = {
    xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
    xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
    xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
    xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE),
  };
  if (xkb_state_mod_name_is_active(state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_DEPRESSED) > 0 &&
      xkb_state_mod_name_is_active(state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_DEPRESSED) > 0)
    m[1] |= mod3;
  if (memcmp(m, mods, sizeof m) != 0) {
    memcpy(mods, m, sizeof m);
    zwp_virtual_keyboard_v1_modifiers(kbd, m[0], m[1], m[2], m[3]);
  }
}

/* A keyboard gone (unplugged, or the USB switch went to another machine):
 * release what it held, or a Ctrl would stay down in the kiosk. */
static void drop(int i) {
  fprintf(stderr, "kiosk-keys: %s is gone\n", devs[i].path);
  for (unsigned code = 0; code <= KEY_MAX; code++)
    if (devs[i].held[code / 8] & (1 << (code % 8))) key(i, code, 0);
  close(devs[i].fd);
  devs[i] = devs[--ndevs];
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: kiosk-keys <glob> <exclude> <xkb-options>\n");
    return 2;
  }
  struct stat ex;
  dev_t exclude = stat(argv[2], &ex) == 0 ? ex.st_rdev : (dev_t)-1;

  struct wl_display *display = wl_display_connect(NULL);
  if (!display) { fprintf(stderr, "kiosk-keys: no Wayland display\n"); return 1; }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!seat || !manager) {
    fprintf(stderr, "kiosk-keys: the compositor offers no virtual keyboard\n");
    return 1;
  }
  kbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);

  char options[512];
  snprintf(options, sizeof options, "%s", argv[3]);
  struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_rule_names names = { "evdev", "pc105", "us", "", options };
  struct xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (!keymap) { fprintf(stderr, "kiosk-keys: bad keymap (%s)\n", options); return 1; }
  char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
  size_t size = strlen(text) + 1;
  int kfd = memfd_create("kiosk-keys-keymap", MFD_CLOEXEC);
  if (kfd < 0 || write(kfd, text, size) != (ssize_t)size) { perror("kiosk-keys: keymap"); return 1; }
  zwp_virtual_keyboard_v1_keymap(kbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, kfd, size);
  wl_display_roundtrip(display);
  close(kfd);
  free(text);
  state = xkb_state_new(keymap);
  xkb_mod_index_t m3 = xkb_keymap_mod_get_index(keymap, "Mod3");
  if (m3 != XKB_MOD_INVALID) mod3 = 1u << m3;

  time_t last_scan = 0;
  for (;;) {
    if (time(NULL) - last_scan >= 2) { scan(argv[1], exclude); last_scan = time(NULL); }

    struct pollfd pfd[MAXDEV + 1];
    pfd[0].fd = wl_display_get_fd(display);
    pfd[0].events = POLLIN;
    for (int i = 0; i < ndevs; i++) { pfd[i + 1].fd = devs[i].fd; pfd[i + 1].events = POLLIN; }
    while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
    wl_display_flush(display);
    int n = poll(pfd, ndevs + 1, 2000);
    if (n < 0 && errno != EINTR) { wl_display_cancel_read(display); perror("kiosk-keys: poll"); return 1; }
    if (n > 0 && (pfd[0].revents & POLLIN)) {
      if (wl_display_read_events(display) != 0) { fprintf(stderr, "kiosk-keys: compositor gone\n"); return 0; }
      wl_display_dispatch_pending(display);
    } else {
      wl_display_cancel_read(display);
    }
    if (pfd[0].revents & (POLLHUP | POLLERR)) { fprintf(stderr, "kiosk-keys: compositor gone\n"); return 0; }

    for (int i = ndevs - 1; i >= 0; i--) {
      if (!(pfd[i + 1].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      struct input_event ev[64];
      ssize_t r = read(devs[i].fd, ev, sizeof ev);
      if (r < 0 && errno == EAGAIN) continue;
      if (r <= 0) { drop(i); continue; }  /* unplugged, or the switch went elsewhere */
      for (size_t k = 0; k < (size_t)r / sizeof ev[0]; k++) {
        if (ev[k].type != EV_KEY || ev[k].value == 2) continue;  /* clients repeat keys themselves */
        key(i, ev[k].code, ev[k].value == 1);
      }
    }
    wl_display_flush(display);
  }
}
