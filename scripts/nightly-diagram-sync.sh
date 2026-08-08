#!/usr/bin/env bash
# Nightly diagram sync — two headless Claude Code sessions with a hard
# boundary between them, driven deterministically from the console container
# (Cronicle dials this via a forced-command SSH key, daily ~08:00, after the
# 07:1x drift checks).
#
#   Session A (PRIVATE): reconcile net-cfgs/network-diagram.md against the
#     four private IaC repos. Runs only when the iac-drift status page says
#     the repos matched reality this morning (doc->repos sync is then safe
#     by transitivity). Commits DIRECTLY to net-cfgs master — but only that
#     one file, added by name, never a sweep (shared checkout).
#
#   Session B (PUBLIC): refresh the architectural SVG component on the blog
#     from the public snapshots' topology. Runs in a scratch dir that
#     contains ONLY public material — a session that read the private repos
#     never writes public content, and vice versa. Its one allowed file is
#     mechanically gated by scan-public.py before commit.
#
# Cheap skip: when neither the private repos nor the public snapshots moved
# since the last run, no Claude session is started at all.
#
# Honesty: Kuma push at the end (so a silent night still beats a dead job —
# the monitor fires on ABSENCE), ntfy summary when something changed or
# failed. Any unexpected failure exits non-zero so Cronicle shows red.
set -euo pipefail

export PATH="$HOME/.local/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

GIT_BASE="$HOME/git/ludorl82"
PRIVATE_REPOS=(nixos-iac k3s-iac cloud-01-iac cloudflare-iac)
PUBLIC_REPOS=(nixos-iac-public k3s-iac-public cloud-01-iac-public cloudflare-iac-public)
STATE_DIR="$HOME/.local/state/nightly-diagram-sync"
STATE="$STATE_DIR/last-heads"
KUMA_STATUS="https://kuma.lab.example/api/status-page/heartbeat/iac-drift"
# push monitor "nightly-diagram-sync" (#57) — URL kept out of the repo,
# same imperative-console-state convention as the ntfy token below
KUMA_PUSH_URL="${KUMA_PUSH_URL:-$(cat "$HOME/.config/kuma-diagram-sync-push" 2>/dev/null || true)}"
NTFY_URL="https://ntfy.lab.example/alerts"
# write-only token for ntfy user diagram-sync — imperative console state
# (like the container's authorized_keys), never committed to any repo
NTFY_TOKEN=$(cat "$HOME/.config/ntfy-diagram-sync-token" 2>/dev/null || true)
LOG_PREFIX="nightly-diagram-sync"

mkdir -p "$STATE_DIR"
summary=()
fail=0

log() { echo "$LOG_PREFIX: $*"; }
notify() { # notify <title> <body>
  [ -n "$NTFY_TOKEN" ] || { log "no ntfy token — skipping notify"; return 0; }
  curl -fsS -m 10 -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $1" \
    -d "$2" "$NTFY_URL" >/dev/null || true
}
kuma() { # kuma <status> <msg>
  [ -n "$KUMA_PUSH_URL" ] && \
    curl -fsS -m 10 "$KUMA_PUSH_URL?status=$1&msg=$(python3 - "$2" <<'PY'
import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))
PY
)" >/dev/null || true
}

# --------------------------------------------------------------------------
# 1. What moved since last night?
# --------------------------------------------------------------------------
heads=""
for r in "${PRIVATE_REPOS[@]}"; do
  git -C "$GIT_BASE/$r" fetch -q origin
  ref=$(git -C "$GIT_BASE/$r" rev-parse -q --verify origin/master 2>/dev/null \
     || git -C "$GIT_BASE/$r" rev-parse origin/main)
  heads+="$r $ref"$'\n'
done
for r in "${PUBLIC_REPOS[@]}"; do
  ref=$(git ls-remote -q "https://github.com/ludorl82/$r.git" HEAD | cut -f1)
  [ -n "$ref" ] || { log "cannot resolve $r HEAD"; exit 1; }
  heads+="$r $ref"$'\n'
done

prev=$(cat "$STATE" 2>/dev/null || true)
# $(cat) strips the trailing newline; strip it from heads too or the
# whole-run skip can never trigger
if [ "${heads%$'\n'}" = "$prev" ]; then
  log "no input changed since last run — skipping"
  kuma up "no change"
  exit 0
fi
priv_changed=0; pub_changed=0
for r in "${PRIVATE_REPOS[@]}"; do
  grep -qF "$(grep "^$r " <<<"$heads")" <<<"$prev" || priv_changed=1
done
for r in "${PUBLIC_REPOS[@]}"; do
  grep -qF "$(grep "^$r " <<<"$heads")" <<<"$prev" || pub_changed=1
done
# first run: treat everything as changed
[ -z "$prev" ] && priv_changed=1 && pub_changed=1

# --------------------------------------------------------------------------
# 2. Session A — private doc reconciliation, gated on green drift checks
# --------------------------------------------------------------------------
run_session_a() {
  local gate
  gate=$(python3 - "$KUMA_STATUS" <<'PY'
import json, sys, urllib.request
from datetime import datetime, timezone
try:
    with urllib.request.urlopen(sys.argv[1], timeout=15) as r:
        d = json.load(r)
    beats = d.get("heartbeatList", {})
    assert beats, "no monitors"
    now = datetime.now(timezone.utc)
    for mid, hb in beats.items():
        last = hb[-1]
        assert last["status"] == 1, f"monitor {mid} down"
        t = datetime.strptime(last["time"][:19], "%Y-%m-%d %H:%M:%S")
        age = (now - t.replace(tzinfo=timezone.utc)).total_seconds()
        assert age < 26 * 3600, f"monitor {mid} stale ({int(age/3600)}h)"
    print("green")
except Exception as e:
    print(f"not-green: {e}")
PY
) || gate="not-green: gate script failed"
  if [ "$gate" != "green" ]; then
    log "drift gate: $gate — skipping session A"
    summary+=("A: skipped ($gate)")
    return 0
  fi

  # make sure the targets are current; net-cfgs is a SHARED checkout, so we
  # snapshot the pre-existing dirt and only ever commit our one file
  git -C "$GIT_BASE/net-cfgs" pull -q --rebase || true
  local before after
  before=$(git -C "$GIT_BASE/net-cfgs" status --porcelain)

  ( cd "$GIT_BASE" && claude -p "$(cat "$GIT_BASE/nixos-iac/scripts/prompts/network-diagram-sync.md")" \
      --allowedTools "Read,Glob,Grep,Edit,Write,Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git status:*)" \
      --max-turns 80 ) || { summary+=("A: claude failed"); fail=1; return 0; }

  after=$(git -C "$GIT_BASE/net-cfgs" status --porcelain)
  local delta
  delta=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | awk '{print $2}' || true)
  if [ -z "$delta" ]; then
    summary+=("A: doc already matched the repos")
    return 0
  fi
  if [ "$delta" != "network-diagram.md" ]; then
    log "session A touched unexpected files: $delta — NOT committing"
    summary+=("A: FAILED (unexpected files: $delta)"); fail=1
    return 0
  fi
  git -C "$GIT_BASE/net-cfgs" add network-diagram.md
  git -C "$GIT_BASE/net-cfgs" commit -q -m "network-diagram: nightly reconcile against the IaC repos

Automated (nightly-diagram-sync, drift checks green tonight).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  git -C "$GIT_BASE/net-cfgs" push -q
  summary+=("A: network-diagram.md reconciled ($(git -C "$GIT_BASE/net-cfgs" rev-parse --short HEAD))")
}

# --------------------------------------------------------------------------
# 3. Session B — public architectural component, in a public-only scratch
# --------------------------------------------------------------------------
run_session_b() {
  local scratch
  scratch=$(mktemp -d /tmp/diagram-sync.XXXXXX)
  trap 'rm -rf "$scratch"' RETURN
  mkdir -p "$scratch/snapshots"
  local r
  for r in "${PUBLIC_REPOS[@]}"; do
    git clone -q --depth 1 "https://github.com/ludorl82/$r.git" "$scratch/snapshots/$r"
  done
  git clone -q --branch dev "git@github.com:ludorl82/labodeludo.dev.git" "$scratch/site"
  python3 "$scratch/site/scripts/topology/join-topology.py" \
    "$scratch/snapshots" "$scratch/site/src/data/architecture.json"
  cp "$scratch/site/src/data/architecture.json" "$scratch/architecture.json"

  ( cd "$scratch" && claude -p "$(cat site/scripts/topology/prompts/arch-diagram.md)" \
      --allowedTools "Read,Glob,Grep,Edit,Write,Bash(npm run build:*),Bash(git diff:*),Bash(git status:*)" \
      --max-turns 60 ) || { summary+=("B: claude failed"); fail=1; return 0; }

  # ignore the join step's own byproducts (architecture.json refresh,
  # python bytecode caches) — only claude's edits count
  local delta
  delta=$(git -C "$scratch/site" status --porcelain | awk '{print $2}' \
    | grep -v -e '^src/data/architecture.json$' -e '__pycache__' || true)
  if [ -z "$delta" ]; then
    summary+=("B: diagram already matched the topology")
    return 0
  fi
  if [ "$delta" != "src/components/LiveArchDiagram.astro" ]; then
    log "session B touched unexpected files: $delta — NOT committing"
    summary+=("B: FAILED (unexpected files: $delta)"); fail=1
    return 0
  fi
  # the gate: fictional shapes only, then the site must still build
  python3 "$scratch/site/scripts/topology/scan-public.py" \
    "$scratch/site/src/components/LiveArchDiagram.astro" \
    || { summary+=("B: FAILED scan-public gate"); fail=1; return 0; }
  ( cd "$scratch/site" && npm ci --silent && SHOW_LIVE_ARCH=1 npm run build >/dev/null ) \
    || { summary+=("B: FAILED build"); fail=1; return 0; }
  git -C "$scratch/site" add src/components/LiveArchDiagram.astro
  git -C "$scratch/site" -c user.name=ludorl82 -c user.email=alerts@example.com \
    commit -q -m "Diagramme architectural : rafraîchissement nocturne

Automatisé (nightly-diagram-sync, données publiques seulement, gate
scan-public passé).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  git -C "$scratch/site" push -q origin dev
  summary+=("B: LiveArchDiagram refreshed ($(git -C "$scratch/site" rev-parse --short HEAD))")
}

[ "$priv_changed" = 1 ] && run_session_a || summary+=("A: skipped (no private change)")
[ "$pub_changed" = 1 ] && run_session_b || summary+=("B: skipped (no public change)")

# --------------------------------------------------------------------------
# 4. Bookkeeping + honesty
# --------------------------------------------------------------------------
msg=$(printf '%s; ' "${summary[@]}")
log "$msg"
if [ "$fail" = 0 ]; then
  printf '%s' "$heads" > "$STATE"
  kuma up "$msg"
  case "$msg" in *reconciled*|*refreshed*) notify "Nightly diagram sync" "$msg" ;; esac
  exit 0
else
  kuma down "$msg"
  notify "Nightly diagram sync FAILED" "$msg"
  exit 1
fi
