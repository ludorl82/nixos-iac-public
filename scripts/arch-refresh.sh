#!/usr/bin/env bash
# The forced command of the Cronicle event "Architecture Refresh (prod)" —
# 05:30 local, last link in the morning chain.
#
# Triggers labodeludo.dev's `architecture.yml`, which clones the four public
# snapshots, joins them into architecture.json, stamps the drift badge from
# Kuma, builds and syncs to the prod bucket. That workflow used to fire on its
# own cron at 09:15 UTC — which is 05:15 LOCAL, i.e. before the drift checks
# and before the Nightly Diagram Sync. Every morning it sealed prod with the
# previous day's drift result and re-rendered components the sync had not
# produced yet. Running it from here, after both, is the entire point of the
# move: the order is now enforced by one scheduler instead of assumed by three.
#
# Note what this does NOT cover: merges to main still refresh prod on their
# own (deploy.yml's prod job runs the same join + stamp), deliberately kept —
# without it a content merge republishes a stale badge over the fresh one.
#
# Takes no arguments — see dispatch-drift-checks.sh for why.
set -u

export PATH="$HOME/.local/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

# shellcheck source=/dev/null
. "$(dirname "$0")/gh-dispatch-lib.sh"

# `main` and not `dev`: production content comes from main, and a refresh that
# built dev would publish unmerged work to the prod bucket.
dispatch_and_wait ludorl82/labodeludo.dev architecture.yml main || exit 1

# The workflow pushes its own Kuma heartbeat ("architecture-nightly"), which
# is absence-shaped and so now also covers "Cronicle never fired". Nothing to
# add here.
echo "arch refresh: prod rebuilt from the current snapshots"
