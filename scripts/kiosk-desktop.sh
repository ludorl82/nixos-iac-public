# kiosk-desktop — the rack kiosk's desktops: switch, load, sleep, keep in step
# with the other kiosk. See modules/kiosk.nix for the why; this is the how.
#
#   kiosk-desktop start        sway startup: one Chromium per desktop, placeholder page
#   kiosk-desktop goto N       numpad: show desktop N here, load it, tell the peer
#   kiosk-desktop prev|next    numpad: neighbour desktop, same as goto
#   kiosk-desktop reload       numpad KP0: reconnect / reload the desktop shown
#   kiosk-desktop sleep        swayidle timeout: log out of every loaded BMC
#   kiosk-desktop resume       swayidle resume: catch up with the peer, load the desktop shown
#   kiosk-desktop peer         forced command for the peer's key (reads SSH_ORIGINAL_COMMAND)
#
# Two kiosks, one picture: every local switch is pushed to the other host so
# flipping the VGA switch never changes what the screen shows. The receiving
# kiosk switches but does NOT log in — a BMC gives out very few sessions, so a
# desktop only loads on local use (a key, or the screen waking up).
#
# Fixed inputs come from the environment (set by the nix wrapper, overridden by
# scripts/tests/kiosk-desktop-test.sh):
#   KIOSK_DESKTOPS     file of "N kind name url" lines, kind = bmc | web |
#                      capture | console (url "-": kiosk-console N); N is the
#                      numpad key (and the sway workspace), keys may have gaps
#   KIOSK_PEER         file holding "name address" of the other kiosk (may be empty)
#   KIOSK_KEY          this host's private key for kiosk@<peer>
#   KIOSK_PWDIR        where the BMC password files live (bmc-<name>)
#   KIOSK_PLACEHOLDER  file:// URL of the "press a key" page
#   KIOSK_PROFILES     where each desktop's Chromium profile lives
#   KIOSK_WM           the compositor running the session: wayfire (the cube)
#                      or sway (the fallback); set by the session script

DESKTOPS="${KIOSK_DESKTOPS:?}"
PWDIR="${KIOSK_PWDIR:-/var/lib/kiosk}"
PROFILES="${KIOSK_PROFILES:-/var/lib/kiosk/chromium}"
PLACEHOLDER="${KIOSK_PLACEHOLDER:?}"
KEY="${KIOSK_KEY:-/var/lib/kiosk/sync/id_ed25519}"
WM="${KIOSK_WM:-sway}"

log() { echo "kiosk-desktop: $*" >&2; }

# Run from the peer's forced command, the environment is bare: find our own
# runtime dir and sway socket.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
if [ "$WM" = sway ] && [ -z "${SWAYSOCK:-}" ]; then
  for s in "$XDG_RUNTIME_DIR"/sway-ipc.*.sock; do [ -S "$s" ] && SWAYSOCK="$s"; done
  export SWAYSOCK
fi
STATE="${KIOSK_STATE:-$XDG_RUNTIME_DIR/kiosk}"
mkdir -p "$STATE"

# The numpad keys in use, in order (2026-10-09: 3 = stella, 4 = bob).
keys=$(awk '$1 ~ /^[1-9]$/ { print $1 }' "$DESKTOPS" | sort -n)
field() { awk -v n="$1" -v f="$2" '$1 == n { print $f }' "$DESKTOPS"; }
port() { echo $((9220 + $1)); }
current() { cat "$STATE/current" 2>/dev/null || head -n 1 <<< "$keys"; }

# Desktop $1's place on Wayfire's row of workspaces: its rank among the keys
# in use (3 -> 0, 4 -> 1), the cube's faces in key order.
index() { awk -v n="$1" '$1 == n { print NR - 1; exit }' <<< "$keys"; }
count() { grep -c . <<< "$keys"; }

chromium_args() {  # desktop $1's Chromium, on its placeholder
  local n=$1
  # --block-new-web-contents: no window.open, not even after a click. bob's
  # BMC page opened the iKVM in a 640x640 popup over the kiosk window, and the
  # watcher then drove the popup (stella, 2026-10-09).
  echo "--ozone-platform=wayland --disable-gpu --no-first-run --no-default-browser-check \
--block-new-web-contents --noerrdialogs --disable-session-crashed-bubble --password-store=basic \
--user-data-dir=$PROFILES/$n --remote-debugging-address=127.0.0.1 \
--remote-debugging-port=$(port "$n") --app=$PLACEHOLDER#$n-$(field "$n" 3)"
}

window() {  # open desktop $1's Chromium (or terminal) on its workspace
  local n=$1
  if [ "$(field "$n" 2)" = console ]; then
    # This host's own console: a terminal asking for a password
    # (kiosk-console, modules/kiosk.nix), app-id kiosk<N>-console.
    if [ "$WM" = sway ]; then
      swaymsg -q "workspace number $n; exec $(command -v kiosk-console) $n"
    else
      nohup kiosk-console "$n" >/dev/null 2>&1 &
      nohup kiosk-wf place "kiosk$n-" "$(index "$n")" >/dev/null 2>&1 &
    fi
    return 0
  fi
  if [ "$WM" = sway ]; then
    # sway runs `exec` with ITS PATH, not ours: hand it Chromium's full path
    # (stella, 2026-10-09: the windows never appeared with a bare `chromium`).
    swaymsg -q "workspace number $n; exec $(command -v chromium) $(chromium_args "$n")"
  else
    # Wayfire cannot start a program on a given workspace: start it, find its
    # window by app-id (Chromium prefixes --app windows' app-id with this
    # variable; --class does not reach them) and send it there, full screen.
    # shellcheck disable=SC2046
    CHROME_WEB_APP_DESKTOP_ID_PREFIX="kiosk$n-" nohup chromium $(chromium_args "$n") >/dev/null 2>&1 &
    nohup kiosk-wf place "kiosk$n-" "$(index "$n")" >/dev/null 2>&1 &
  fi
}

alive() {  # is desktop $1's Chromium (or terminal) running?
  if [ "$(field "$1" 2)" = console ]; then
    pgrep -u "$(id -u)" -f -- "--app-id=kiosk$1-console( |$)" >/dev/null
  else
    pgrep -u "$(id -u)" -f -- "--user-data-dir=$PROFILES/$1( |$)" >/dev/null
  fi
}
valid() { case "$1" in [1-9]) grep -qx "$1" <<< "$keys" ;; *) false ;; esac; }

show() {  # switch the screen to desktop $1, nothing else; $2 = instant
  local n=$1 from to right left
  if [ "$WM" = sway ]; then
    swaymsg -q "workspace number $n"
  elif [ "${2:-}" = instant ]; then
    kiosk-wf show "$(index "$n")"
  else
    # The cube: turn by the shorter way round to the desktop's face. A jump
    # by vswitch/set-workspace would slide, not turn.
    from=$(kiosk-wf current); to=$(index "$n")
    if [ "$from" != "$to" ]; then
      right=$(( (to - from + $(count)) % $(count) )); left=$(( $(count) - right ))
      if [ "$right" -le "$left" ]; then kiosk-wf rotate right "$right"
      else kiosk-wf rotate left "$left"; fi
    fi
  fi
  echo "$n" > "$STATE/current"
}

stop_watch() {  # stop desktop $1's watcher: its pid file, and any stray one
  local n=$1
  if [ -s "$STATE/watch-$n" ]; then kill "$(cat "$STATE/watch-$n")" 2>/dev/null || true; fi
  rm -f "$STATE/watch-$n"
  # A watcher whose pid file was lost (window reopened, file overwritten) kept
  # its BMC session: two watchers on bob's page took turns kicking each other
  # off, "Server disconnected (code: 1006)" (stella, 2026-10-09).
  pkill -u "$(id -u)" -f -- "kiosk-bmc watch $(port "$n") " || true
}

load() {  # make desktop $1 live, once
  local n=$1 kind name url
  # A desktop whose Chromium died (stella, 2026-10-09: desktop 2 crashed with
  # SIGTRAP 9 s after boot) gets a new window, and logs in again.
  if ! alive "$n"; then
    stop_watch "$n"
    rm -f "$STATE/loaded-$n"
    window "$n"
    sleep 3
  fi
  kind=$(field "$n" 2); name=$(field "$n" 3); url=$(field "$n" 4)
  # A BMC console that fell (session closed by the BMC: "disconnection due to
  # user logout", 1006, back on the login page — bob, 2026-10-09) reconnects
  # when its key is pressed, instead of waiting for KP0 or the watcher.
  if [ -e "$STATE/loaded-$n" ] && [ "$kind" = bmc ] \
     && [ "$(kiosk-bmc state "$(port "$n")" 2>/dev/null)" != ok ]; then
    unload "$n"
  fi
  [ -e "$STATE/loaded-$n" ] && return 0
  if [ "$kind" = console ]; then
    touch "$STATE/loaded-$n"   # live as soon as its terminal is: it asks for the password
    return 0
  fi
  if [ "$kind" = bmc ]; then
    if [ ! -r "$PWDIR/bmc-$name" ]; then
      log "no password file $PWDIR/bmc-$name: desktop $n stays on its placeholder"
      return 0
    fi
    kiosk-bmc login "$(port "$n")" "$url" "$PWDIR/bmc-$name" || { log "login to $name failed"; return 0; }
    # Stay attached: dismiss the BMC's alerts, reconnect after a timeout or a
    # dropped viewer (kiosk-bmc watch). Stopped by unload. One per desktop.
    stop_watch "$n"
    nohup kiosk-bmc watch "$(port "$n")" "$url" "$PWDIR/bmc-$name" >/dev/null 2>&1 &
    echo $! > "$STATE/watch-$n"
  else
    kiosk-bmc open "$(port "$n")" "$url" || return 0
  fi
  touch "$STATE/loaded-$n"
}

unload() {  # give desktop $1's BMC session back (or close its console)
  local n=$1
  [ -e "$STATE/loaded-$n" ] || return 0
  if [ "$(field "$n" 2)" = console ]; then
    # No shell stays open on a screen nobody watches: the terminal goes, and
    # load() opens a fresh one, at the password prompt.
    pkill -u "$(id -u)" -f -- "--app-id=kiosk$n-console( |$)" || true
    rm -f "$STATE/loaded-$n"
    return 0
  fi
  stop_watch "$n"
  if [ "$(field "$n" 2)" = bmc ]; then
    kiosk-bmc logout "$(port "$n")" "$(field "$n" 4)" "$PLACEHOLDER#$n-$(field "$n" 3)" || true
  fi
  rm -f "$STATE/loaded-$n"
}

peer_addr() { [ -s "${KIOSK_PEER:-}" ] && awk 'NR == 1 { print $2 }' "$KIOSK_PEER"; }

tell_peer() {  # fire and forget: a dead peer must not slow the numpad down
  local addr; addr=$(peer_addr) || return 0
  if [ -z "$addr" ] || [ ! -r "$KEY" ]; then return 0; fi
  ( timeout 5 ssh -n -o BatchMode=yes -o ConnectTimeout=2 -i "$KEY" "kiosk@$addr" "$*" \
      >/dev/null 2>&1 & )
}

ask_peer() {  # the peer's current desktop, or nothing
  local addr; addr=$(peer_addr) || return 0
  if [ -z "$addr" ] || [ ! -r "$KEY" ]; then return 0; fi
  timeout 4 ssh -n -o BatchMode=yes -o ConnectTimeout=2 -i "$KEY" "kiosk@$addr" get 2>/dev/null || true
}

neighbour() {  # $1 = prev|next among the keys in use, wraps around
  local list nxt; list=$keys
  if [ "$1" = prev ]; then list=$(sort -rn <<< "$keys"); fi
  nxt=$(awk -v n="$(current)" 'found { print; exit } $1 == n { found = 1 }' <<< "$list")
  if [ -z "$nxt" ]; then nxt=$(head -n 1 <<< "$list"); fi
  echo "$nxt"
}

wake() {  # the numpad woke us: screen on, idle timer restarted
  # evsieve takes the pad for itself (its digits must not be typed into the
  # console shown), so the compositor never sees those keys and swayidle never
  # resumes on them — only the mouse woke the screen (2026-10-09). The pad's
  # commands turn the screen back on themselves, and restart swayidle (its
  # loop in the session starts a fresh one) so the ten minutes count again.
  [ -e "$STATE/asleep" ] || return 0
  rm -f "$STATE/asleep"
  if [ "$WM" = sway ]; then swaymsg -q 'output * power on'; else wlopm --on '*'; fi
  pkill -u "$(id -u)" -x swayidle || true
}

resume() {  # catch up with the peer, then load what is shown
  local n; n=$(ask_peer)
  if valid "$n" && [ "$n" != "$(current)" ]; then show "$n"; fi
  load "$(current)"
}

cmd="${1:-}"
case "$cmd" in
  start)
    rm -f "$STATE"/loaded-*
    # One at a time: two Chromiums starting in the same second is when
    # desktop 2 crashed. load() reopens any that dies anyway.
    for n in $keys; do window "$n"; sleep 2; done
    show "$(head -n 1 <<< "$keys")" instant
    resume
    ;;
  goto)
    n="${2:-}"; valid "$n" || { log "bad desktop '$n'"; exit 1; }
    wake; show "$n"; tell_peer goto "$n"; load "$n"
    ;;
  prev|next)
    wake; n=$(neighbour "$cmd"); show "$n"; tell_peer goto "$n"; load "$n"
    ;;
  reload)
    wake; n=$(current)
    case "$(field "$n" 2)" in
      bmc|console) unload "$n"; load "$n" ;;
      *) kiosk-bmc reload "$(port "$n")" || true ;;
    esac
    ;;
  sleep)
    for n in $keys; do unload "$n"; done
    touch "$STATE/asleep"
    ;;
  resume)
    rm -f "$STATE/asleep"
    resume
    ;;
  peer)
    # Forced command: the peer may only switch our screen or ask where we are.
    # shellcheck disable=SC2086
    set -- ${SSH_ORIGINAL_COMMAND:-}
    case "${1:-}" in
      get) current ;;
      goto) if [ $# -ne 2 ] || ! valid "$2"; then
              log "peer: denied '${SSH_ORIGINAL_COMMAND:-}'"; exit 1
            fi
            show "$2" ;;
      *) log "peer: denied '${SSH_ORIGINAL_COMMAND:-}'"; exit 1 ;;
    esac
    ;;
  *)
    log "usage: kiosk-desktop start|goto N|prev|next|reload|sleep|resume|peer"; exit 1 ;;
esac
