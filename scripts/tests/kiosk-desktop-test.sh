#!/usr/bin/env bash
# Tests for scripts/kiosk-desktop.sh (modules/kiosk.nix).
#
# What matters on the rack: a BMC desktop logs in once and only when used
# HERE (the BMCs hand out very few sessions), every local switch is pushed to
# the other kiosk, a switch FROM the other kiosk never logs in and never
# bounces back, and the peer's key can do nothing but switch or ask.
#
# swaymsg, ssh, chromium and kiosk-bmc are fakes that log their arguments;
# nothing here needs sway or a BMC.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kiosk-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
count_of() { if [ -f "$1" ]; then grep -c -- "$2" "$1"; else echo 0; fi; }
expect() { local got; got=$(count_of "$1" "$2"); [ "$got" = "$3" ] && ok "$4" || bad "$4: expected $3 × '$2' in $(basename "$1"), got $got"; }

mkdir -p "$ROOT/bin" "$ROOT/tools" "$ROOT/run" "$ROOT/pw"

# Only the commands the module puts on the script's PATH (runtimeInputs),
# mapped to what they provide; openssh/sway/chromium/kioskBmc are the fakes.
MODULE="$SCRIPTS/../modules/kiosk.nix"
inputs=$(sed -n 's/.*runtimeInputs = with pkgs; \[\(.*\)\];.*/\1/p' "$MODULE")
[ -n "$inputs" ] || { echo "could not read runtimeInputs from $MODULE"; exit 1; }
ln -s "$(command -v bash)" "$ROOT/tools/bash"
for pkg in $inputs; do
  case "$pkg" in
    coreutils) cmds="cat id mkdir rm touch seq timeout echo sleep nohup sort head" ;;
    gnugrep)   cmds="grep" ;;
    gawk)      cmds="awk" ;;
    openssh|sway|wlopm|chromium|kioskBmc|kioskWf|kioskConsole|procps) cmds="" ;;
    *) echo "unknown runtime input '$pkg': map it in this test"; exit 1 ;;
  esac
  for c in $cmds; do p=$(command -v "$c") && ln -sf "$p" "$ROOT/tools/$c"; done
done

# pgrep: a desktop's Chromium is "running" unless $ROOT/dead-<n> exists.
cat > "$ROOT/bin/pgrep" <<PGREP
#!/usr/bin/env bash
for n in 1 2 3 4 5 6 7; do case "\$*" in *"/profiles/\$n("*|*"kiosk\$n-console("*) [ -e "$ROOT/dead-\$n" ] && exit 1; exit 0 ;; esac; done
exit 0
PGREP
# kiosk-wf: logs; "current" answers $ROOT/wf-current (default 0).
cat > "$ROOT/bin/kiosk-wf" <<WF
#!/usr/bin/env bash
echo "\$*" >> "$ROOT/kiosk-wf.log"
[ "\$1" = current ] && cat "$ROOT/wf-current" 2>/dev/null || true
WF
# kiosk-bmc: logs; "state" answers $ROOT/bmc-state (default ok).
cat > "$ROOT/bin/kiosk-bmc" <<BMC
#!/usr/bin/env bash
echo "\$*" >> "$ROOT/kiosk-bmc.log"
[ "\$1" = state ] && { cat "$ROOT/bmc-state" 2>/dev/null || echo ok; }
exit 0
BMC
for f in swaymsg chromium wlopm pkill kiosk-console; do
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/%s.log"\n' "$ROOT" "$f" > "$ROOT/bin/$f"
done
# ssh: log the remote command (last argument); "get" answers $ROOT/peer-current.
cat > "$ROOT/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\${@: -1}" >> "$ROOT/ssh.log"
[ "\${@: -1}" = get ] && cat "$ROOT/peer-current" 2>/dev/null
exit 0
EOF
chmod +x "$ROOT"/bin/*

cat > "$ROOT/desktops" <<EOF
1 bmc bob https://bob.ipmi.lab.example
2 bmc luna https://luna.ipmi.lab.example
3 web lab https://example.invalid
EOF
echo "bob 192.0.2.129" > "$ROOT/peer"
echo key > "$ROOT/key"
echo secret > "$ROOT/pw/bmc-bob"
echo secret > "$ROOT/pw/bmc-luna"

run() {  # run kiosk-desktop with the fakes, then let background pushes land
  env -i PATH="$ROOT/bin:$ROOT/tools" HOME="$ROOT" XDG_RUNTIME_DIR="$ROOT/run" SWAYSOCK="$ROOT/sock" \
    KIOSK_WM="${WM:-sway}" \
    KIOSK_DESKTOPS="$ROOT/desktops" KIOSK_PEER="$ROOT/peer" KIOSK_KEY="$ROOT/key" \
    KIOSK_PWDIR="$ROOT/pw" KIOSK_PROFILES="$ROOT/profiles" KIOSK_PLACEHOLDER="file:///ph.html" \
    SSH_ORIGINAL_COMMAND="${SSH_CMD:-}" bash "$SCRIPTS/kiosk-desktop.sh" "$@" 2>"$ROOT/stderr"
  local rc=$?; sleep 0.3; return $rc
}
reset() { rm -f "$ROOT"/*.log "$ROOT/run/kiosk/"* "$ROOT/peer-current" "$ROOT/wf-current" "$ROOT/bmc-state"; }

say "start: one Chromium per desktop on a placeholder, nothing logged in until used"
reset
run start
expect "$ROOT/swaymsg.log" "exec $ROOT/bin/chromium " 3 "three Chromium windows, by full path (sway has its own PATH)"
expect "$ROOT/swaymsg.log" "remote-debugging-port=9222" 1 "desktop 2 debugs on 9222"
expect "$ROOT/swaymsg.log" "block-new-web-contents" 3 "no popups in any kiosk window"
expect "$ROOT/kiosk-bmc.log" "login 9221" 1 "the shown desktop (1) logs in at start"
expect "$ROOT/kiosk-bmc.log" "login 9222" 0 "desktop 2 does not"

say "goto: switch, push to the peer, log in once"
run goto 2
expect "$ROOT/swaymsg.log" "workspace number 2" 2 "switched to 2"
expect "$ROOT/ssh.log" "goto 2" 1 "pushed to the peer"
expect "$ROOT/kiosk-bmc.log" "login 9222 https://luna.ipmi.lab.example $ROOT/pw/bmc-luna" 1 "logged into luna's BMC"
run goto 2
expect "$ROOT/kiosk-bmc.log" "login 9222" 1 "a second goto 2 does not log in again"
expect "$ROOT/kiosk-bmc.log" "watch 9222 https://luna.ipmi.lab.example" 1 "a watcher stays on luna's BMC page"
[ -s "$ROOT/run/kiosk/watch-2" ] && ok "its pid is kept" || bad "no watch-2 pid file"
run goto 3
expect "$ROOT/kiosk-bmc.log" "open 9223 https://example.invalid" 1 "a web desktop just opens its url"

say "goto: bad input"
run goto 7; [ $? -ne 0 ] && ok "desktop 7 refused" || bad "desktop 7 accepted"
run goto x; [ $? -ne 0 ] && ok "'x' refused" || bad "'x' accepted"

say "next/prev wrap around"
reset; echo 3 > "$ROOT/run/kiosk/current"
run next; [ "$(cat "$ROOT/run/kiosk/current")" = 1 ] && ok "next from 3 is 1" || bad "next from 3"
run prev; [ "$(cat "$ROOT/run/kiosk/current")" = 3 ] && ok "prev from 1 is 3" || bad "prev from 1"

say "sleep: log out of every loaded BMC, and only those"
reset
run goto 1; run goto 2
run sleep
expect "$ROOT/kiosk-bmc.log" "logout 9221 https://bob.ipmi.lab.example file:///ph.html#1-bob" 1 "bob logged out"
expect "$ROOT/kiosk-bmc.log" "logout 9222" 1 "luna logged out"
[ ! -e "$ROOT/run/kiosk/watch-2" ] && ok "and its watcher is stopped" || bad "watch-2 still there after sleep"
run goto 1
expect "$ROOT/kiosk-bmc.log" "login 9221" 2 "after sleep, using bob again logs in again"

say "peer: switches, never logs in, never pushes back"
reset
SSH_CMD="goto 2" run peer
expect "$ROOT/swaymsg.log" "workspace number 2" 1 "the peer's goto switches the screen"
expect "$ROOT/kiosk-bmc.log" "login" 0 "but does not log in"
expect "$ROOT/ssh.log" "goto" 0 "and does not push back"
SSH_CMD="get" run peer > "$ROOT/out"; [ "$(cat "$ROOT/out")" = 2 ] && ok "get answers 2" || bad "get answered '$(cat "$ROOT/out")'"

say "peer: anything else is denied"
for c in "goto 9" "goto 1 2" "goto 1; rm -rf /" "start" "sleep" "" "reload"; do
  SSH_CMD="$c" run peer >/dev/null; [ $? -ne 0 ] && ok "denied: '$c'" || bad "accepted: '$c'"
done
expect "$ROOT/kiosk-bmc.log" "." 0 "no denied command reached kiosk-bmc"

say "resume: catch up with the peer, then load what is shown"
reset; echo 1 > "$ROOT/run/kiosk/current"; echo 2 > "$ROOT/peer-current"
run resume
[ "$(cat "$ROOT/run/kiosk/current")" = 2 ] && ok "followed the peer to 2" || bad "did not follow the peer"
expect "$ROOT/kiosk-bmc.log" "login 9222" 1 "and logged into the desktop shown"

say "missing password file: placeholder stays, no crash"
reset; rm -f "$ROOT/pw/bmc-bob"
run goto 1; [ $? -eq 0 ] && ok "goto 1 still succeeds" || bad "goto 1 failed"
expect "$ROOT/kiosk-bmc.log" "login" 0 "no login attempted without a password file"

say "a desktop whose Chromium died gets a new window and logs in again"
reset; run goto 2; rm -f "$ROOT"/*.log; touch "$ROOT/dead-2"
run goto 2
expect "$ROOT/swaymsg.log" "user-data-dir=$ROOT/profiles/2 " 1 "desktop 2's window reopened"
expect "$ROOT/kiosk-bmc.log" "login 9222" 1 "and logged in again"
expect "$ROOT/pkill.log" "-f -- kiosk-bmc watch 9222 " 2 "the old watcher is stopped, even without its pid file"
expect "$ROOT/kiosk-bmc.log" "watch 9222" 1 "and exactly one new watcher starts"
rm -f "$ROOT/dead-2"

say "a fallen BMC console reconnects when its key is pressed"
reset; run goto 2; rm -f "$ROOT"/kiosk-bmc.log
echo dropped > "$ROOT/bmc-state"
run goto 2
expect "$ROOT/kiosk-bmc.log" "logout 9222" 1 "the fallen session is logged out"
expect "$ROOT/kiosk-bmc.log" "login 9222" 1 "and logged in again"
rm -f "$ROOT/bmc-state" "$ROOT"/kiosk-bmc.log
run goto 2
expect "$ROOT/kiosk-bmc.log" "login 9222" 0 "a live console is left alone"

say "the numpad wakes the screen it put to sleep"
reset
run sleep; [ -e "$ROOT/run/kiosk/asleep" ] && ok "sleep marks the screen asleep" || bad "no asleep marker"
WM=wayfire run goto 2 >/dev/null 2>&1
expect "$ROOT/wlopm.log" "^--on" 1 "a pad key turns the screen back on"
expect "$ROOT/pkill.log" "swayidle" 1 "and restarts the idle timer"
[ ! -e "$ROOT/run/kiosk/asleep" ] && ok "no longer asleep" || bad "still asleep"
rm -f "$ROOT/wlopm.log" "$ROOT/pkill.log"
WM=wayfire run goto 1 >/dev/null 2>&1
expect "$ROOT/wlopm.log" "." 0 "an awake screen is left alone"

say "dead peer: no peer file, the switch still happens"
reset; : > "$ROOT/peer"
run goto 2; [ "$(cat "$ROOT/run/kiosk/current")" = 2 ] && ok "switched with no peer" || bad "no switch"
expect "$ROOT/ssh.log" "." 0 "nothing pushed"

say "keys with gaps (2026-10-09: 3 = luna, 4 = bob)"
cat > "$ROOT/desktops" <<KEYS
3 bmc luna https://luna.ipmi.lab.example
4 bmc bob https://bob.ipmi.lab.example
KEYS
reset
run start
[ "$(cat "$ROOT/run/kiosk/current")" = 3 ] && ok "start shows the first key in use (3)" || bad "start shows $(cat "$ROOT/run/kiosk/current")"
expect "$ROOT/swaymsg.log" "remote-debugging-port=9224" 1 "desktop 4 debugs on 9224"
run goto 1; [ $? -ne 0 ] && ok "key 1 (unused) refused" || bad "key 1 accepted"
run next; [ "$(cat "$ROOT/run/kiosk/current")" = 4 ] && ok "next from 3 is 4" || bad "next from 3"
run next; [ "$(cat "$ROOT/run/kiosk/current")" = 3 ] && ok "next from 4 wraps to 3" || bad "next from 4"
run prev; [ "$(cat "$ROOT/run/kiosk/current")" = 4 ] && ok "prev from 3 wraps to 4" || bad "prev from 3"
SSH_CMD="goto 2" run peer >/dev/null; [ $? -ne 0 ] && ok "the peer cannot pick an unused key" || bad "peer goto 2 accepted"

say "a console desktop: a terminal on this host, nothing to log into, closed on sleep"
cat > "$ROOT/desktops" <<KEYS
3 bmc luna https://luna.ipmi.lab.example
6 console kiosque -
KEYS
reset; touch "$ROOT/dead-6"
run start
expect "$ROOT/swaymsg.log" "workspace number 6; exec $ROOT/bin/kiosk-console 6$" 1 "desktop 6 opens kiosk-console, by full path"
expect "$ROOT/swaymsg.log" "exec $ROOT/bin/chromium " 1 "a Chromium for desktop 3 only"
rm -f "$ROOT/dead-6" "$ROOT"/*.log
run goto 6
[ -e "$ROOT/run/kiosk/loaded-6" ] && ok "marked live: it asks for the password itself" || bad "desktop 6 not marked live"
expect "$ROOT/kiosk-bmc.log" "9226" 0 "no BMC login, no page for the console"
run sleep
expect "$ROOT/pkill.log" "kiosk6-console" 1 "the screen sleeps: the terminal (and any shell in it) goes"
[ -e "$ROOT/run/kiosk/loaded-6" ] && bad "still marked live after sleep" || ok "no longer live"
rm -f "$ROOT"/*.log; touch "$ROOT/dead-6"
run resume
expect "$ROOT/swaymsg.log" "kiosk-console 6$" 1 "awake again: a fresh terminal, at the password prompt"
rm -f "$ROOT/dead-6" "$ROOT"/*.log
run reload
expect "$ROOT/pkill.log" "kiosk6-console" 1 "KP0 on the console: a fresh terminal too"
reset; touch "$ROOT/dead-6"
WM=wayfire run start
expect "$ROOT/kiosk-console.log" "^6$" 1 "under wayfire, kiosk-console started directly"
expect "$ROOT/kiosk-wf.log" "^place kiosk6- 1$" 1 "and placed on its face"
rm -f "$ROOT/dead-6"

say "wayfire: the cube turns the shorter way, start jumps without it"
cat > "$ROOT/desktops" <<KEYS
1 bmc bob https://bob.ipmi.lab.example
3 bmc luna https://luna.ipmi.lab.example
4 web lab https://example.invalid
KEYS
reset
WM=wayfire run start
expect "$ROOT/kiosk-wf.log" "^show 0$" 1 "start shows the first face at once"
expect "$ROOT/kiosk-wf.log" "^place kiosk3- 1$" 1 "desktop 3's window goes to face 1"
expect "$ROOT/chromium.log" "remote-debugging-port=9224" 1 "desktop 4's Chromium is started directly"
expect "$ROOT/swaymsg.log" "." 0 "no swaymsg under wayfire"
rm -f "$ROOT/kiosk-wf.log"; echo 0 > "$ROOT/wf-current"
WM=wayfire run goto 3
expect "$ROOT/kiosk-wf.log" "^rotate right 1$" 1 "face 0 to 1: one turn right"
rm -f "$ROOT/kiosk-wf.log"; echo 0 > "$ROOT/wf-current"
WM=wayfire run goto 4
expect "$ROOT/kiosk-wf.log" "^rotate left 1$" 1 "face 0 to 2 of 3: one turn left, the shorter way"
rm -f "$ROOT/kiosk-wf.log"; echo 1 > "$ROOT/wf-current"
WM=wayfire run goto 3
expect "$ROOT/kiosk-wf.log" "^rotate" 0 "already on the face: no turn"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
