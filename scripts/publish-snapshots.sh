#!/usr/bin/env bash
# The forced command of the Cronicle event "Public IaC Snapshots (manual)".
#
# Publishes all six sanitized public snapshots. Deliberately NOT on a
# schedule: this is the one step in the diagram pipeline that crosses the
# private->public boundary, and the decision to cross it stays a human one.
# Everything downstream (the nightly sync's redraw, the 05:30 prod refresh)
# consumes whatever this last published — so if the drawing looks stale, this
# is the job that has not been run.
#
# Usage (manually, on the console):
#   publish-snapshots.sh --dry-run    # sanitize + gate + report, push nothing
#   publish-snapshots.sh              # what Cronicle runs
#
# The forced-command key passes no arguments, so Cronicle always gets the real
# thing; --dry-run exists for running it by hand before trusting a change.
#
# --allow-local publishes a checkout that is not sitting on origin's default
# branch. See the refusal below for why that needs asking for.
set -u

export PATH="$HOME/.local/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

GIT_BASE="$HOME/git/ludorl82"
# pfsense-iac and ha-iac joined on 2026-09-28. ha-iac's "snapshot" is not a
# copy of the repo: its sanitizer emits only smart-home.json, an allowlisted
# summary — a home's configuration describes the people in it.
REPOS=(nixos-iac k3s-iac cloud-01-iac cloudflare-iac pfsense-iac ha-iac)
RESCUE_DIR="$HOME/.local/state/publish-snapshots/rescue"
DRY_RUN=0
ALLOW_LOCAL=0
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY_RUN=1 ;;
    --allow-local) ALLOW_LOCAL=1 ;;
    *) echo "publish-snapshots: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

fail=0
summary=()
log() { echo "publish-snapshots: $*"; }

work=$(mktemp -d /tmp/publish-snapshots.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$RESCUE_DIR"

for r in "${REPOS[@]}"; do
  src="$GIT_BASE/$r"
  pub="ludorl82/$r-public"

  # --- refuse to publish anything that is not committed -------------------
  # These are SHARED checkouts: other sessions edit them, and the sanitizer
  # reads the working TREE, not HEAD. Publishing a dirty tree would push
  # someone's in-flight edit to a public repo, which is not recoverable by
  # force-pushing it away — see the EIP incident in net-cfgs history.
  if [ -n "$(git -C "$src" status --porcelain 2>/dev/null)" ]; then
    log "$r: working tree is DIRTY — refusing (commit or stash first)"
    summary+=("$r: REFUSED (dirty tree)"); fail=1; continue
  fi
  git -C "$src" fetch -q origin 2>/dev/null || true
  head=$(git -C "$src" rev-parse HEAD)
  remote=$(git -C "$src" rev-parse -q --verify origin/cp-1 2>/dev/null \
        || git -C "$src" rev-parse -q --verify origin/main 2>/dev/null || echo "")
  # --- refuse to publish anything that is not origin's default branch -----
  # This used to be a warning. It read "publishing the LOCAL tree" and then
  # published it, which is a footgun on a SHARED checkout: on 2026-09-23 three
  # of these four were sitting on feature branches, two of them belonging to
  # other sessions, and running this job would have pushed that unmerged work
  # to public repositories. The sanitizer still runs, so it would not have
  # been a leak — it would have been someone's draft published under the
  # project's name, and a force-push does not unpublish what has been fetched.
  #
  # A warning in a log nobody reads at the moment of the push is not a
  # control. Refusing is, and the checkout is one `git checkout cp-1` away.
  #
  # An unresolvable origin is refused too: not knowing what we are about to
  # publish is precisely the case this guard exists for, and the rest of this
  # script is fail-closed for the same reason.
  if [ "$ALLOW_LOCAL" = 1 ]; then
    [ "$head" != "$remote" ] && log "$r: --allow-local: publishing the LOCAL tree, not origin"
  elif [ -z "$remote" ]; then
    log "$r: no origin/cp-1 or origin/main — refusing (cannot tell what would be published)"
    summary+=("$r: REFUSED (no origin branch)"); fail=1; continue
  elif [ "$head" != "$remote" ]; then
    log "$r: on $(git -C "$src" rev-parse --abbrev-ref HEAD) at $(git -C "$src" rev-parse --short HEAD), origin is $(echo "$remote" | cut -c1-7) — REFUSING (checkout origin's branch, or pass --allow-local)"
    summary+=("$r: REFUSED (not on origin)"); fail=1; continue
  fi

  # --- sanitize (the gate is fail-closed and lives inside this script) ----
  out="$work/$r-public"
  if ! "$src/scripts/sanitize-public.sh" "$out" >"$work/$r.log" 2>&1; then
    log "$r: sanitizer REFUSED the tree — not publishing"
    sed 's/^/  /' "$work/$r.log" | tail -20 >&2
    summary+=("$r: REFUSED (gate)"); fail=1; continue
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "$r: gate passed ($(find "$out" -type f | wc -l) files) — dry run, not pushing"
    summary+=("$r: gate ok (dry run)")
    continue
  fi

  # --- rescue the current public HEAD before overwriting it --------------
  # A force-push unlinks the old commit; it does not delete it, but nothing
  # local keeps a copy either. Bundle first so a bad publish is recoverable
  # without depending on GitHub still resolving the orphaned SHA.
  mirror="$work/$r-mirror"
  if git clone -q --mirror "https://github.com/$pub.git" "$mirror" 2>/dev/null; then
    git -C "$mirror" bundle create \
      "$RESCUE_DIR/$r-$(date -u +%Y%m%dT%H%M%SZ).bundle" --all >/dev/null 2>&1 \
      || log "$r: WARNING could not bundle the previous snapshot"
    tags=$(git -C "$mirror" tag -l 'article/*' | tr '\n' ' ')
  else
    log "$r: WARNING could not clone the published snapshot — no rescue bundle"
    tags=""
  fi

  # --- publish as a single-commit orphan tree ----------------------------
  # The convention (net-cfgs history, 2026-08-07): one commit, no history,
  # force-pushed. History would carry every earlier sanitizer's misses
  # forward forever, which is the opposite of what the gate is for.
  (
    cd "$out" || exit 1
    git init -q -b main
    git add -A
    git -c user.name=ludorl82 -c user.email=alerts@example.com \
      commit -q -m "Sanitized public snapshot — $(date -u +%Y-%m-%d)

Generated by publish-snapshots.sh from the private repository at
$(git -C "$src" rev-parse --short HEAD). Single-commit orphan tree by
design: the sanitizer's verification gate passes on THIS tree, and
publishing history would carry forward whatever earlier revisions of
those rules missed."
    git remote add origin "git@github.com:$pub.git"
    git push -q --force origin main
  ) || { log "$r: push FAILED"; summary+=("$r: FAILED (push)"); fail=1; continue; }

  # --- article tags are LEFT ALONE, on purpose ---------------------------
  # Each article/* tag pins the tree as that article described it, so they
  # legitimately point at older commits — today nixos-iac-public's HEAD is one
  # commit and two of its three tags are on another. Moving them would make
  # every published article link to today's tree instead of the one it was
  # written about.
  #
  # net-cfgs history has a line about "both article tags deleted and recreated
  # on it — a tag left behind keeps the old commit reachable and buys
  # nothing". That was the 2026-08-07 REMEDIATION, when the old commits held a
  # leaked elastic IP and unreachability was the point. It is not the standing
  # rule, and every republish since has left the tags where they were.
  #
  # Consequence worth stating: tagged commits stay reachable, so a leak in one
  # of them is not undone by republishing. If that ever matters again, moving
  # the tags is a deliberate one-off, not something this job should do nightly.
  short=$(cd "$out" && git rev-parse --short HEAD)
  stale=""
  for t in $tags; do
    tsha=$(git -C "$mirror" rev-list -n1 "$t" 2>/dev/null | cut -c1-7)
    [ -n "$tsha" ] && stale="$stale $t@$tsha"
  done
  log "$r: published $short${stale:+ (tags left in place:$stale)}"
  summary+=("$r: published $short")
done

echo
log "summary: $(printf '%s; ' "${summary[@]}")"
if [ "$fail" != 0 ]; then
  log "one or more repos were not published — see above"
  exit 1
fi
[ "$DRY_RUN" = 1 ] && log "dry run: nothing was pushed"
exit 0
