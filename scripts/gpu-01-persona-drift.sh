#!/usr/bin/env bash
# The forced command of the Cronicle event "gpu-01 persona drift" — 05:40 local,
# after the morning chain. Kuma push monitor 76, fires on absence.
#
# gpu-01 is described in ONE file, labodeludo.dev/src/data/gpu-01-persona.md, and
# served in pieces: the chat Worker reads its Chat section from the site's
# /gpu-01-grounding.json, Home Assistant's voice assistant carries a render of
# its Voix section in its own storage. Nothing in the deploy path notices
# when either copy stops matching the file — a prompt edited by hand in HA,
# a merge nobody applied, a prod built from something else. The job stays
# green, the house just sounds a little off.
#
# The comparison itself lives NEXT TO THE PERSONA, in the site repo
# (scripts/voice/check-gpu-01-drift.sh): this only clones main, runs it, and
# pushes the verdict. Same discipline as run-from-cp-1.sh and for the same
# reason — a script pasted into a Cronicle event is a script nobody reviews.
#
# MAIN, not dev: prod is built from main, so main's Chat section is what the
# published fingerprint must equal. A dev-only edit is a pending change, not
# drift.
#
# Takes no arguments, deliberately: forced-command key, one script.
set -uo pipefail
export PATH="$HOME/.local/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

# URL kept out of the repo, same imperative-console-state convention as the
# other push monitors (daily-gpu-01-sync, diagram-sync).
KUMA_PUSH_URL="${KUMA_PUSH_URL:-$(cat "$HOME/.config/kuma-gpu-01-drift-push" 2>/dev/null || true)}"
kuma() { # kuma <up|down> <msg>
  [ -n "$KUMA_PUSH_URL" ] || { echo "gpu-01-persona-drift: no kuma push url — skipping heartbeat"; return 0; }
  curl -fsS --max-time 10 -G "$KUMA_PUSH_URL" \
    --data-urlencode "status=$1" --data-urlencode "msg=$2" >/dev/null 2>&1 \
    || echo "gpu-01-persona-drift: kuma push failed (non-fatal)"
}

scratch=$(mktemp -d /tmp/gpu-01-persona-drift.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

if ! git clone -q --depth 1 --branch main git@github.com:ludorl82/labodeludo.dev.git "$scratch/site" 2>&1; then
  # Cannot check is not "disagrees": say so, stay silent, and let the absence
  # of a beat be the alarm if it keeps happening.
  echo "gpu-01-persona-drift: could not clone labodeludo.dev main"
  exit 2
fi
echo "gpu-01-persona-drift: labodeludo.dev main at $(git -C "$scratch/site" rev-parse --short HEAD)"

out=$("$scratch/site/scripts/voice/check-gpu-01-drift.sh" 2>&1); rc=$?
echo "$out"
summary=$(echo "$out" | grep -E '^(voice|chat):' | tr '\n' ';' | sed 's/;$//')
case $rc in
  0) kuma up "$summary" ;;
  1) kuma down "$summary"; exit 1 ;;
  *) echo "gpu-01-persona-drift: comparison unavailable (rc=$rc), no verdict pushed"; exit 2 ;;
esac
