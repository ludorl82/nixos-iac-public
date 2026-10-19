#!/usr/bin/env bash
# The forced command of the Cronicle event "Console instantané" — 23:00 local.
# Kuma push monitor (absence-shaped), URL in ~/.config/kuma-console-instantane-push.
#
# Publishes the public snapshot of the console's tmux session « claude » that
# the top of labodeludo.dev/casts/ shows: every window, the conversation in it,
# sanitized. The work — reading the transcripts, the private replacements, the
# allowlist and denylist, the review by qwen38-27b on bob — lives in the SITE
# repo (scripts/console/instantane.mjs), next to the page that reads it; this
# only clones main, feeds it the private config, and uploads the result.
#
# MAIN, not dev: the snapshot crosses private -> public with no human in the
# loop, so it must run code that was reviewed and merged, never a dev branch.
#
# The private half comes from net-cfgs ORIGIN/cp-1 (console-instantane.txt,
# public-denylist.txt), read with `git show` after a fetch: the checkout on
# the console is shared with interactive sessions and may sit on any branch.
#
# Fail closed. Any error before the upload means no upload: yesterday's
# snapshot stays up, Kuma goes down with the reason, and an exit code that is
# not 0 turns the Cronicle event red. Never a less-guarded snapshot.
#
# The detailed report (which guard removed which passage) is this job's log,
# on the console, under ~/.local/state/jobs/console-instantane/. It names real
# hosts' replacement targets and passage numbers; it never goes public.
#
# Takes no arguments, deliberately: forced-command key, one script.
set -uo pipefail
export PATH="$HOME/.local/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

KUMA_PUSH_URL="${KUMA_PUSH_URL:-$(cat "$HOME/.config/kuma-console-instantane-push" 2>/dev/null || true)}"
kuma() { # kuma <up|down> <msg>
  [ -n "$KUMA_PUSH_URL" ] || { echo "console-instantane: no kuma push url — skipping heartbeat"; return 0; }
  curl -fsS --max-time 10 -G "$KUMA_PUSH_URL" \
    --data-urlencode "status=$1" --data-urlencode "msg=$2" >/dev/null 2>&1 \
    || echo "console-instantane: kuma push failed (non-fatal)"
}
fail() { echo "console-instantane: $1"; kuma down "$1"; exit 1; }

NETCFGS="$HOME/git/ludorl82/net-cfgs"
BUCKET="s3://labodeludo.dev/console/instantane.json"
PUBLIC="https://labodeludo.dev/console/instantane.json"

scratch=$(mktemp -d /tmp/console-instantane.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
umask 077

git clone -q --depth 1 --branch main git@github.com:ludorl82/labodeludo.dev.git "$scratch/site" 2>&1 \
  || fail "could not clone labodeludo.dev main"
echo "console-instantane: labodeludo.dev main at $(git -C "$scratch/site" rev-parse --short HEAD)"
[ -f "$scratch/site/scripts/console/instantane.mjs" ] || fail "main has no scripts/console/instantane.mjs yet"

git -C "$NETCFGS" fetch -q origin cp-1 2>&1 || fail "could not fetch net-cfgs"
git -C "$NETCFGS" show origin/cp-1:console-instantane.txt > "$scratch/config.txt" \
  || fail "net-cfgs cp-1 has no console-instantane.txt"
git -C "$NETCFGS" show origin/cp-1:public-denylist.txt > "$scratch/denylist.txt" \
  || fail "net-cfgs cp-1 has no public-denylist.txt"

PUBLIC_DENYLIST_FILE="$scratch/denylist.txt" \
  node "$scratch/site/scripts/console/instantane.mjs" \
    --config "$scratch/config.txt" --out "$scratch/instantane.json" 2>&1 \
  || fail "the snapshot did not complete — nothing uploaded"

read_json() { # read_json <file> : prints "<generated>\t<summary>"
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
w = d["windows"]
pub = [x for x in w if x["status"] == "publiee"]
gone = sum(x.get("retirees", 0) for x in pub)
print(d["generated"] + "\t" + f"{len(pub)} publiées, {len(w) - len(pub)} retenues, {gone} passages retirés")
PY
}
meta=$(read_json "$scratch/instantane.json") || fail "the snapshot is not readable JSON"
generated=${meta%%$'\t'*}
summary=${meta#*$'\t'}

aws s3 cp "$scratch/instantane.json" "$BUCKET" --only-show-errors \
  --content-type application/json --cache-control "public, max-age=300" 2>&1 \
  || fail "upload to S3 failed — yesterday's snapshot stays up"

# Read it back the way a visitor would. A cache-busting query, because the
# point is to see what the origin now serves, not what an edge kept.
served=$(curl -fsS --max-time 20 "$PUBLIC?v=$(date +%s)" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["generated"])' 2>/dev/null) || served=""
[ "$served" = "$generated" ] || fail "uploaded $generated but the site serves '${served:-nothing}'"

echo "console-instantane: published $generated — $summary"
kuma up "$summary"
