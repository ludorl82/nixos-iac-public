#!/usr/bin/env bash
# Shared by the Cronicle dispatcher scripts (dispatch-drift-checks.sh,
# arch-refresh.sh). Sourced, not executed.
#
# Cronicle's policy in this lab is that it *triggers* jobs rather than doing
# their work, and these scripts are the thinnest possible expression of that:
# the GitHub workflow still does everything, Cronicle just decides when.
#
# The whole reason this is more than one line: `gh workflow run` returns as
# soon as GitHub accepts the dispatch, which would make every Cronicle run
# green regardless of what the workflow did. Resolving the new run id and
# watching it to completion is what makes the dashboard's red mean something.

# dispatch_and_wait <repo> <workflow-file> <ref>
#   -> 0 if the workflow run succeeded, non-zero otherwise
dispatch_and_wait() {
  local repo="$1" wf="$2" ref="$3" before id i

  # Remember the newest run BEFORE dispatching. GitHub assigns the new run's
  # id asynchronously, so "newest id changed" is the only reliable signal that
  # ours exists yet — there is no id in the dispatch response to key off.
  before=$(gh run list -R "$repo" --workflow="$wf" -L 1 \
             --json databaseId -q '.[0].databaseId // 0' 2>/dev/null || echo 0)

  if ! gh workflow run "$wf" --ref "$ref" -R "$repo" >/dev/null 2>&1; then
    echo "$repo/$wf: dispatch REFUSED (bad ref, missing workflow_dispatch, or auth)" >&2
    return 1
  fi

  id="$before"
  for i in $(seq 1 30); do
    sleep 2
    id=$(gh run list -R "$repo" --workflow="$wf" -L 1 \
           --json databaseId -q '.[0].databaseId // 0' 2>/dev/null || echo 0)
    [ "$id" != "$before" ] && [ "$id" != 0 ] && break
  done
  if [ "$id" = "$before" ] || [ "$id" = 0 ]; then
    # Dispatched but never appeared: do NOT report success. A silently
    # dropped trigger is exactly the failure this wrapper exists to catch.
    echo "$repo/$wf: dispatched but no run appeared within 60s" >&2
    return 1
  fi

  echo "$repo/$wf: run $id dispatched, waiting..."
  if gh run watch "$id" -R "$repo" --exit-status --compact >/dev/null 2>&1; then
    echo "$repo/$wf: run $id SUCCESS"
    return 0
  fi
  echo "$repo/$wf: run $id FAILED — https://github.com/$repo/actions/runs/$id" >&2
  return 1
}
