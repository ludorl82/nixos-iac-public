#!/usr/bin/env bash
# End-to-end harness for nightly-diagram-sync.sh.
#
# The driver derives everything from $HOME — GIT_BASE, the state dir, the
# credential files, and (line 48) PATH itself, which it resets to
# $HOME/.local/bin first. So a fake HOME is enough to own the whole world it
# runs in: repos, remotes, `claude`, `npm`, Kuma, ntfy. The only things not
# already derived are the hardcoded GitHub URLs, which git's
# `url.<base>.insteadOf` rewrites to local bare repos, and the drift-gate URL,
# which reads $KUMA_STATUS.
#
# Nothing here touches the real repos, the real remotes, or the real monitor.
#
#   ./nightly-diagram-sync-test.sh            # all scenarios
#   ./nightly-diagram-sync-test.sh race       # one scenario
set -uo pipefail

DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nightly-diagram-sync.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dsync-test.XXXXXX")
# DSYNC_KEEP=1 leaves the fake worlds behind for post-mortem
[ -n "${DSYNC_KEEP:-}" ] && trap 'printf "\nworlds kept: %s\n" "$ROOT"' EXIT \
                         || trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0; only="${1:-}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
# check <description> <regex> — asserts against the captured run output
check() { grep -Eq "$2" "$OUT" && ok "$1" || { bad "$1"; printf '       wanted /%s/\n' "$2"; }; }
nocheck() { grep -Eq "$2" "$OUT" && { bad "$1"; printf '       did NOT want /%s/\n' "$2"; } || ok "$1"; }
# kuma_was <up|down> — did the driver actually push that status to the monitor?
# This is the honesty assertion: every scenario must reach the monitor, and
# with the right verdict. A silent night is the bug we are testing for.
kuma_was() { grep -q "GET /push?status=$1" "$KUMA_LOG" 2>/dev/null; }

# --------------------------------------------------------------------------
# A world the driver can run in
# --------------------------------------------------------------------------
# $1 = home dir to build. Creates bare "remotes" + working clones for the 4
# private repos, net-cfgs, the 4 public snapshots and the site.
build_world() {
  local H="$1" r
  export HOME="$H"
  mkdir -p "$H/git/ludorl82" "$H/remotes" "$H/.local/bin" "$H/.config"

  gitq() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

  for r in nixos-iac k3s-iac cloud-01-iac cloudflare-iac net-cfgs; do
    git init -q --bare "$H/remotes/$r.git"
    git clone -q "$H/remotes/$r.git" "$H/git/ludorl82/$r" 2>/dev/null
    echo "seed" > "$H/git/ludorl82/$r/README.md"
    gitq "$H/git/ludorl82/$r" add README.md
    gitq "$H/git/ludorl82/$r" commit -qm seed
    gitq "$H/git/ludorl82/$r" push -q origin HEAD:cp-1
    gitq "$H/git/ludorl82/$r" branch -q --set-upstream-to=origin/cp-1 cp-1 2>/dev/null
  done
  # the docs the private sessions reconcile
  for f in network-diagram.md physical-layout.md; do echo "# $f" > "$H/git/ludorl82/net-cfgs/$f"; done
  gitq "$H/git/ludorl82/net-cfgs" add -A
  gitq "$H/git/ludorl82/net-cfgs" commit -qm docs
  gitq "$H/git/ludorl82/net-cfgs" push -q

  # the prompts the driver feeds to `claude`
  mkdir -p "$H/git/ludorl82/nixos-iac/scripts/prompts"
  for p in network-diagram-sync.md physical-layout-sync.md fleet-seed.md; do
    echo "prompt $p" > "$H/git/ludorl82/nixos-iac/scripts/prompts/$p"
  done
  gitq "$H/git/ludorl82/nixos-iac" add -A
  gitq "$H/git/ludorl82/nixos-iac" commit -qm prompts
  gitq "$H/git/ludorl82/nixos-iac" push -q

  # public snapshots
  for r in nixos-iac-public k3s-iac-public cloud-01-iac-public cloudflare-iac-public; do
    git init -q --bare "$H/remotes/$r.git"
    local t="$ROOT/mk-$r"; rm -rf "$t"; git clone -q "$H/remotes/$r.git" "$t" 2>/dev/null
    echo '{"nodes":[]}' > "$t/topology.json"
    gitq "$t" add -A; gitq "$t" commit -qm seed; gitq "$t" push -q origin HEAD:cp-1
  done

  # the site, on dev
  git init -q --bare "$H/remotes/labodeludo.dev.git"
  local s="$ROOT/mk-site"; rm -rf "$s"; git clone -q "$H/remotes/labodeludo.dev.git" "$s" 2>/dev/null
  mkdir -p "$s/src/components" "$s/src/data" "$s/scripts/topology/prompts"
  echo "prompt arch" > "$s/scripts/topology/prompts/arch-diagram.md"
  echo "prompt rack" > "$s/scripts/topology/prompts/rack-diagram.md"
  { echo '<svg>'; for i in $(seq 1 12); do echo "  <g data-node=\"n$i\"></g>"; done; echo '</svg>'; } \
    > "$s/src/components/LiveArchDiagram.astro"
  echo '<svg>{fleet.devices.map(d => d)}</svg>' > "$s/src/components/RackDiagram.astro"
  echo '{"devices":[{"name":"x"}]}' > "$s/src/data/fleet.json"
  echo '{}' > "$s/src/data/architecture.json"
  cat > "$s/scripts/topology/join-topology.py" <<'PY'
import sys, json, pathlib
# regenerates architecture.json — the unstaged byproduct that made every push
# race look like a content conflict before rebase.autoStash
pathlib.Path(sys.argv[2]).write_text(json.dumps({"generated": "now", "nodes": []}) + "\n")
print("join-topology: fixture ->", sys.argv[2])
PY
  cat > "$s/scripts/topology/scan-public.py" <<'PY'
import sys
print(f"scan-public: {len(sys.argv)-1} file(s) clean")
sys.exit(0)
PY
  echo "node_modules/" > "$s/.gitignore"
  gitq "$s" add -A; gitq "$s" commit -qm seed; gitq "$s" push -q origin HEAD:dev
  # the driver reads the published seed here to decide if the seed ever ran
  git clone -q --branch dev "$H/remotes/labodeludo.dev.git" "$H/git/ludorl82/labodeludo.dev" 2>/dev/null

  # rewrite the driver's hardcoded GitHub URLs to our bare repos
  git config --global --replace-all url."$H/remotes/".insteadOf "https://github.com/ludorl82/"
  git config --global --add url."$H/remotes/".insteadOf "git@github.com:ludorl82/"
  git config --global init.defaultBranch cp-1
  git config --global user.email t@t
  git config --global user.name t

  # A real listener, so we can read the status= the driver actually pushed.
  # (file:// cannot work here — the driver GETs the URL, it does not write it.)
  KUMA_LOG="$H/kuma-requests.log"
  # banner (port) goes to stdout, request lines to stderr — capture both
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$H" >"$KUMA_LOG" 2>&1 &
  KUMA_PID=$!
  local port=""
  for _ in $(seq 1 50); do
    port=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$KUMA_LOG" 2>/dev/null | head -1)
    [ -n "$port" ] && break
    sleep 0.1
  done
  [ -n "$port" ] || { echo "FATAL: no Kuma stub port"; exit 1; }
  echo "http://127.0.0.1:$port/push" > "$H/.config/kuma-diagram-sync-push"
}

# Stub `claude`. $CLAUDE_MODE decides what the "sessions" do.
install_stubs() {
  local H="$HOME"
  cat > "$H/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Which session is this? The driver passes the prompt as one argument.
mode="${CLAUDE_MODE:-normal}"
prompt="$*"
case "$prompt" in
  *"prompt network-diagram-sync.md"*) sess=A ;;
  *"prompt physical-layout-sync.md"*) sess=C ;;
  *"prompt fleet-seed.md"*)           sess=SEED ;;
  *"prompt arch"*)                    sess=B ;;
  *"prompt rack"*)                    sess=D ;;
  *)                                  sess=? ;;
esac
echo "[stub claude: session $sess, mode $mode]"
[ "$mode" = "fail-$sess" ] && exit 1
case "$sess" in
  A) echo "reconciled" >> "$GIT/net-cfgs/network-diagram.md"
     [ "$mode" = "stray" ] && echo "oops" >> "$GIT/net-cfgs/physical-layout.md" ;;
  C) echo "reconciled" >> "$GIT/net-cfgs/physical-layout.md" ;;
  SEED) mkdir -p "$FLEET_SCRATCH_DIR"
        cat > "$FLEET_OUT_FILE" <<'JSON'
{"devices":[{"name":"sw-01","class":"switch","location":"rack-a","rackOrder":1}]}
JSON
     ;;
  B) f=site/src/components/LiveArchDiagram.astro
     [ -f "$f" ] || f=src/components/LiveArchDiagram.astro
     if [ "$mode" = "strip-interactivity" ]; then echo '<svg>bare</svg>' > "$f"
     else { echo '<svg>redrawn'; for i in $(seq 1 12); do echo "  <g data-node=\"n$i\"></g>"; done; echo '</svg>'; } > "$f"; fi ;;
  D) echo '<svg>racks redrawn {fleet.devices.map(d => d)}</svg>' > src/components/RackDiagram.astro
     # the 2026-08-08 case: a scratch file the sandbox would not let it delete
     [ "$mode" = "byproduct" ] && echo "// scratch" > .rack-layout-check.mjs
     # a genuinely alarming stray: a TRACKED file outside the deliverable set
     [ "$mode" = "tracked-stray" ] && echo "meddled" >> .gitignore ;;
esac
exit 0
STUB
  chmod +x "$H/.local/bin/claude"

  cat > "$H/.local/bin/npm" <<'STUB'
#!/usr/bin/env bash
[ "${NPM_MODE:-ok}" = "fail" ] && { echo "npm: build failed"; exit 1; }
echo "[stub npm $*]"; exit 0
STUB
  chmod +x "$H/.local/bin/npm"

  # the driver resets PATH to $HOME/.local/bin first, then system dirs; real
  # git/python3/curl still resolve there. Symlink anything unusual if needed.
  for t in git python3 curl mktemp date comm awk grep sed tr head; do
    command -v "$t" >/dev/null || echo "WARNING: $t missing"
  done
}

# A green drift gate served from a file:// URL the gate's urllib can read.
write_gate() { # write_gate <green|red>
  local now; now=$(date -u +"%Y-%m-%d %H:%M:%S")
  local status=1; [ "$1" = red ] && status=0
  printf '{"heartbeatList":{"1":[{"status":%s,"time":"%s"}]}}' "$status" "$now" \
    > "$HOME/gate.json"
  export KUMA_STATUS="file://$HOME/gate.json"
}

# run_driver <label> [env assignments...] — captures output to $OUT
run_driver() {
  OUT="$ROOT/out.$1"; shift
  ( export GIT="$HOME/git/ludorl82" \
           FLEET_OUT_FILE="$HOME/.cache/nightly-diagram-sync/fleet.json" \
           FLEET_SCRATCH_DIR="$HOME/git/ludorl82/.diagram-scratch"
    mkdir -p "$(dirname "$FLEET_OUT_FILE")"
    env "$@" bash "$DRIVER" ) > "$OUT" 2>&1
  RC=$?
  printf '  (exit %s)\n' "$RC"
}

# fresh <name> — a brand-new world, stubs installed, gate green
fresh() {
  [ -n "${KUMA_PID:-}" ] && kill "$KUMA_PID" 2>/dev/null; KUMA_PID=""
  local H="$ROOT/home-$1"; rm -rf "$H"
  build_world "$H" >"$ROOT/build.$1.log" 2>&1 || { echo "world build FAILED, see $ROOT/build.$1.log"; exit 1; }
  install_stubs
  write_gate green
}

want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

# --------------------------------------------------------------------------
# Scenarios
# --------------------------------------------------------------------------
if want happy; then
  say "happy path: everything moved, everything lands"
  fresh happy
  run_driver happy
  check "session A committed"            'A: network-diagram\.md reconciled'
  check "session C committed"            'C: physical-layout\.md reconciled'
  check "seed passed both gates"         'seed: fleet\.json passed both gates'
  check "B redrew"                       'B: architecture redrawn'
  check "D redrew"                       'D: racks redrawn'
  check "B/D pushed"                     'B/D: pushed'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  kuma_was up   && ok "Kuma pushed UP"   || bad "Kuma pushed UP"
  # the real assertions: did the work actually reach the remotes?
  git -C "$HOME/remotes/net-cfgs.git" log --oneline -1 2>/dev/null | grep -q reconcile \
    && ok "net-cfgs remote advanced" || bad "net-cfgs remote advanced"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/components/LiveArchDiagram.astro 2>/dev/null \
    | grep -q redrawn && ok "site remote has the redraw" || bad "site remote has the redraw"
fi

if want skip; then
  say "no input moved: the whole run is skipped"
  fresh skip
  run_driver skip1 >/dev/null
  run_driver skip2
  check "second run skips"  'no input changed since last run'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
fi

if want race; then
  say "push race on dev: rebase, retry, land (the 2026-08-08 failure)"
  fresh race
  # a competing commit lands on dev while the driver is mid-run: the stub
  # pushes it from inside session B, which is exactly when the real one hit
  cat > "$HOME/.local/bin/claude.race" <<'STUB'
#!/usr/bin/env bash
t=$(mktemp -d); git clone -q --branch dev "$HOME/remotes/labodeludo.dev.git" "$t/s" 2>/dev/null
echo "meanwhile" > "$t/s/src/content-new.md"
git -C "$t/s" add -A
git -C "$t/s" -c user.email=t@t -c user.name=t commit -qm "someone else pushed"
git -C "$t/s" push -q origin dev; rm -rf "$t"
STUB
  chmod +x "$HOME/.local/bin/claude.race"
  # wrap the stub so session B triggers the competing push first
  mv "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.real"
  cat > "$HOME/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"prompt arch"*) "$HOME/.local/bin/claude.race" ;; esac
exec "$HOME/.local/bin/claude.real" "$@"
STUB
  chmod +x "$HOME/.local/bin/claude"
  run_driver race
  check "the race was detected and rebased" 'push race on origin/dev — rebased, retrying'
  check "and the push then landed"          'B/D: pushed'
  nocheck "no bogus conflict report"        'conflicts with the remote'
  nocheck "nothing was discarded"           'DISCARDED|FAILED to push'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/components/LiveArchDiagram.astro 2>/dev/null \
    | grep -q redrawn && ok "redraw survived the race" || bad "redraw survived the race"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/content-new.md >/dev/null 2>&1 \
    && ok "the other commit survived too" || bad "the other commit survived too"
fi

if want conflict; then
  say "genuine conflict: refuse, rescue the commit, report down"
  fresh conflict
  mv "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.real"
  cat > "$HOME/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
# push a conflicting edit to the SAME file session B is about to redraw
case "$*" in *"prompt arch"*)
  t=$(mktemp -d); git clone -q --branch dev "$HOME/remotes/labodeludo.dev.git" "$t/s" 2>/dev/null
  echo '<svg>theirs</svg>' > "$t/s/src/components/LiveArchDiagram.astro"
  git -C "$t/s" add -A
  git -C "$t/s" -c user.email=t@t -c user.name=t commit -qm "conflicting redraw"
  git -C "$t/s" push -q origin dev; rm -rf "$t" ;;
esac
exec "$HOME/.local/bin/claude.real" "$@"
STUB
  chmod +x "$HOME/.local/bin/claude"
  run_driver conflict
  check "conflict detected, not resolved"  'conflicts with the remote — not resolving'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  check "the commit was rescued"           'FAILED to push — commit rescued'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  b=$(ls "$HOME/.local/state/nightly-diagram-sync/rescue/"*.bundle 2>/dev/null | head -1)
  if [ -n "$b" ]; then
    ok "rescue bundle exists"
    t="$ROOT/recover"; rm -rf "$t"
    git clone -q --branch dev "$HOME/remotes/labodeludo.dev.git" "$t" 2>/dev/null
    if git -C "$t" fetch -q "$b" 2>/dev/null && \
       git -C "$t" show FETCH_HEAD:src/components/LiveArchDiagram.astro 2>/dev/null | grep -q redrawn
    then ok "the lost redraw is recoverable from the bundle"
    else bad "the lost redraw is recoverable from the bundle"; fi
  else bad "rescue bundle exists"; fi
fi

if want session-fail; then
  say "a session fails: reported, and the night is red"
  fresh sessionfail
  run_driver sessfail CLAUDE_MODE=fail-A
  check "A reported as failed" 'A: claude failed'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  check "C still ran"          'C: physical-layout\.md reconciled'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
fi

if want stray; then
  say "a session touches a file it shouldn't: nothing is committed"
  fresh stray
  run_driver stray CLAUDE_MODE=stray
  check "stray files refused"   'A: FAILED \(unexpected files'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  nocheck "nothing committed"   'A: network-diagram\.md reconciled'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
fi

if want interactivity; then
  say "B strips the click targets: the gate catches it"
  fresh interactivity
  run_driver interact CLAUDE_MODE=strip-interactivity
  check "interactivity contract enforced" 'B: FAILED interactivity contract'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:src/components/LiveArchDiagram.astro 2>/dev/null \
    | grep -q bare && bad "the stripped file must NOT be on the remote" \
    || ok "the stripped file never reached the remote"
fi

if want build-fail; then
  say "the build fails: nothing is pushed"
  fresh buildfail
  run_driver buildfail NPM_MODE=fail
  check "build failure reported" 'B/D: FAILED build'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  nocheck "nothing pushed"       'B/D: pushed'
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
fi

if want gate-red; then
  say "drift gate red: the private sessions do not run"
  fresh gatered
  write_gate red
  run_driver gatered
  check "A skipped on the gate" 'A: skipped \(not-green'
  check "C skipped on the gate" 'C: skipped \(not-green'
  nocheck "A did not commit"    'A: network-diagram\.md reconciled'
fi

if want death; then
  say "the driver dies unexpectedly: the monitor still hears about it"
  fresh death
  # make a mid-run command explode: remove a private repo after the heads scan
  cat > "$HOME/.local/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"prompt network-diagram-sync.md"*) rm -rf "$HOME/git/ludorl82/net-cfgs/.git" ;; esac
exit 0
STUB
  chmod +x "$HOME/.local/bin/claude"
  run_driver death
  check "the death was reported to Kuma" 'driver died \(exit'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  [ "$RC" != 0 ] && ok "non-zero exit" || bad "non-zero exit (got $RC)"
fi

if want byproduct; then
  say "a session leaves an undeletable scratch file: swept, not fatal"
  fresh byproduct
  run_driver byproduct CLAUDE_MODE=byproduct
  check "the byproduct was swept"  'swept session scratch files.*rack-layout-check\.mjs'
  check "B still redrew"           'B: architecture redrawn'
  check "D still redrew"           'D: racks redrawn'
  check "and it all landed"        'B/D: pushed'
  nocheck "the guard did not fire" 'unexpected files'
  [ "$RC" = 0 ] && ok "exit 0" || bad "exit 0 (got $RC)"
  kuma_was up && ok "Kuma pushed UP" || bad "Kuma pushed UP"
  git -C "$HOME/remotes/labodeludo.dev.git" show dev:.rack-layout-check.mjs >/dev/null 2>&1 \
    && bad "the scratch file must NOT be on the remote" || ok "the scratch file never reached the remote"
fi

if want tracked-stray; then
  say "a session edits a tracked file it shouldn't: refuse, but keep the work"
  fresh trackedstray
  run_driver trackedstray CLAUDE_MODE=tracked-stray
  check "the real guard still fires" 'FAILED \(unexpected files'
  check "deliverables were rescued"  'deliverables saved to'
  kuma_was down && ok "Kuma pushed DOWN" || bad "Kuma pushed DOWN"
  [ "$RC" = 1 ] && ok "exit 1" || bad "exit 1 (got $RC)"
  pt=$(ls "$HOME/.local/state/nightly-diagram-sync/rescue/"stray-refusal-*.patch 2>/dev/null | head -1)
  if [ -n "$pt" ]; then
    ok "rescue patch exists"
    t="$ROOT/recover-patch"; rm -rf "$t"
    git clone -q --branch dev "$HOME/remotes/labodeludo.dev.git" "$t" 2>/dev/null
    if git -C "$t" apply "$pt" 2>/dev/null && grep -q redrawn "$t/src/components/LiveArchDiagram.astro"; then
      ok "the refused redraw re-applies cleanly"
    else bad "the refused redraw re-applies cleanly"; fi
  else bad "rescue patch exists"; fi
fi

printf '\n\033[1m%s passed, %s failed\033[0m\n' "$pass" "$failed"
[ "$failed" = 0 ]
