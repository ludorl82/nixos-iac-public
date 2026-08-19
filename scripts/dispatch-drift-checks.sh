#!/usr/bin/env bash
# The forced command of the Cronicle event "IaC Drift Checks (cloud-01 +
# cloudflare)" — 04:30 local, first link in the morning chain.
#
# Both workflows used to carry their own GitHub `schedule:` cron (11:15 and
# 11:30 UTC). Two problems with that, both fixed by moving the trigger here:
# GitHub cron is UTC with no timezone support, so those times slipped an hour
# against local time under EST; and the drift checks are what gates the
# Nightly Diagram Sync twenty minutes later, so their timing was a convention
# two schedulers had to agree on rather than something anyone enforced.
#
# nixos-iac's drift check is NOT here: it already ran as its own Cronicle
# event (it executes in the Cronicle pod, no GitHub workflow involved) and
# stays that way, retimed to 04:40.
#
# Takes no arguments, deliberately: this is a forced-command key, and the
# whole point of that scoping is that a leaked key can run this one script
# and nothing else. A wrapper reading $SSH_ORIGINAL_COMMAND would give it
# back the generality the restriction exists to remove.
set -u

export PATH="$HOME/.local/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

# shellcheck source=/dev/null
. "$(dirname "$0")/gh-dispatch-lib.sh"

rc=0

# Order is not significant — they check different clouds and neither feeds the
# other. Run them in sequence anyway: together they take well under a minute,
# and a serial log is far easier to read at 04:30 than an interleaved one.
# `cp-1`, not `main`: these two repos predate the newer default and still
# use it. gh refuses a dispatch against a ref that does not exist, so the
# wrong branch name here is a silent no-op dressed as a failure.
dispatch_and_wait ludorl82/cloud-01-iac        drift.yml cp-1 || rc=1
dispatch_and_wait ludorl82/cloudflare-iac drift.yml cp-1 || rc=1

# Each workflow pushes its own Kuma heartbeat (monitors 40 and 43), so there
# is deliberately no push here — a second opinion about the same run would
# only ever disagree by being wrong. Cronicle's own red/green is the signal
# that the *trigger* worked.
[ "$rc" = 0 ] && echo "drift dispatch: both workflows succeeded"
exit $rc
