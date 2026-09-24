#!/usr/bin/env bash
# Promote or roll back the flake.lock canary. Runs in the console container
# on console-vm, daily at 20:00 via the Cronicle event "nixos-iac canary
# promotion" (same forced-command key as "Daily IaC updates"; the script
# scripts/weekly-iac-updates.sh routes to this one after 18:00).
#
# The canary is the `canary` branch: cp-1 plus this week's flake.lock bump
# (scripts/update-flake-lock.sh). vm-01 and vm-02 follow it as comin's
# testing branch and switch to it on their own. This script is the judge:
#
#   PROMOTE  when both canaries report the canary commit as their running
#            configurationRevision, are `running`, are Ready in k3s, the
#            LOCK is at least SOAK old (author date: a rebase replays the same
#            lock, so it does not restart the soak), and the PR's eval check
#            is green
#            → merge the PR (fast-forwards cp-1; comin deploys the fleet).
#   ROLLBACK when a canary is unreachable or has not deployed the commit
#            DEPLOY_GRACE after it was pushed (comin build failed, or the
#            switch took the host down), or is deployed but unhealthy an hour
#            after the push → reset `canary` to cp-1 (comin only deploys a
#            testing branch strictly ahead of cp-1, so the canaries switch
#            back to cp-1's generation on their own), close the PR with the
#            reasons, page ntfy.
#   REBASE   when cp-1 moved under the canary (another merge) → rebase the
#            one flake.lock commit onto cp-1 and force-push. The soak clock
#            does NOT restart — it is the lock that soaks, and the rebase did
#            not touch it. Only the deploy/health graces restart, since the
#            canaries do have a new closure to build. A rebase conflict resets
#            the branch instead; next Sunday's bump starts fresh.
#   WAIT     otherwise, saying why.
#
# Deliberately not consulted: Kuma. Monitors 71/72 are the same SSH port this
# script already talks to, and a promotion should not hinge on a cache.
#
# Exit 0 = judged (any verdict). Non-zero = the judge itself is broken.
set -uo pipefail
# Cronicle gives this job a bare environment, so the PATH is set here rather
# than inherited. FLAKE_CANARY_PATH_PREFIX is a test seam and nothing else:
# scripts/tests/flake-canary-test.sh puts stub ssh/gh/kubectl ahead of the
# real ones so the whole verdict flow can run against a local bare repo with
# no network and no fleet. Unset in production, which is every caller but the
# test.
export PATH="${FLAKE_CANARY_PATH_PREFIX:+$FLAKE_CANARY_PATH_PREFIX:}/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

REPO=ludorl82/nixos-iac
BRANCH=canary
CANARIES="${CANARIES:-vm-01 vm-02}"
BASTION="${BASTION:-pi-02}"           # every fleet SSH hop goes through the jumphost
SOAK="${SOAK:-86400}"                   # 24 h
DEPLOY_GRACE="${DEPLOY_GRACE:-7200}"    # 2 h for comin to build + switch
HEALTH_GRACE="${HEALTH_GRACE:-3600}"    # 1 h before a degraded canary counts
WORK="$HOME/.iac-updates/nixos-iac"
NTFY_TOKEN_FILE="$HOME/.config/iac-updates/ntfy-token"
NTFY_URL="https://ntfy.pub.example.com/alerts"

log() { echo "[$(date -u +%FT%TZ)] $*"; }
ntfy() {  # title priority body
  [ -r "$NTFY_TOKEN_FILE" ] || { log "ntfy (no token file): $1 | $3"; return 0; }
  curl -fsS -m 15 -H "Authorization: Bearer $(cat "$NTFY_TOKEN_FILE")" -H "X-Title: $1" -H "X-Priority: $2" \
    -d "$3" "$NTFY_URL" >/dev/null 2>&1 || log "ntfy failed"
}
remote() {  # host cmd — via the jumphost, batch mode, short timeouts
  ssh -4 -n -o BatchMode=yes -o ConnectTimeout=10 "$BASTION" \
    "ssh -n -o BatchMode=yes -o ConnectTimeout=10 $1 '$2'" 2>/dev/null | tr -d '\r'
}

[ -d "$WORK/.git" ] || git clone -q "git@github.com:$REPO.git" "$WORK" || { echo "BROKEN: clone"; exit 1; }
cd "$WORK"
git fetch -q origin --prune || { echo "BROKEN: fetch"; exit 1; }
cp-1=$(git rev-parse origin/cp-1)
canary=$(git rev-parse -q --verify "origin/$BRANCH" 2>/dev/null || true)

if [ -z "$canary" ] || [ "$canary" = "$cp-1" ]; then
  log "no canary in flight (canary = cp-1)"
  exit 0
fi
short=${canary:0:7}

# --- cp-1 moved under the canary -----------------------------------------
if ! git merge-base --is-ancestor "$cp-1" "$canary"; then
  log "cp-1 moved under canary $short; rebasing"
  git checkout -q -B "$BRANCH" "origin/$BRANCH"
  if git rebase -q origin/cp-1; then
    git push -q -f origin "$BRANCH"
    # Says what the two clocks now do, because the old wording said "soak
    # clock restarts" and that is exactly the behaviour #76 removed. A log
    # line that describes the bug it replaced is worse than none: this is the
    # line an operator reads at 20:00 to decide whether the canary is stuck.
    log "canary rebased onto cp-1 ($(git rev-parse --short HEAD)); soak keeps running (it follows the lock), deploy grace restarts"
  else
    git rebase --abort
    git push -q -f origin "cp-1:$BRANCH"
    ntfy "flake canary: dropped" default "canary $short did not rebase onto cp-1; branch reset. Next Sunday's bump starts fresh."
    log "rebase conflict; canary reset to cp-1"
  fi
  git checkout -q cp-1
  exit 0
fi

# TWO CLOCKS, because "how long has this lock been soaking" and "how long
# have the canaries had this commit to build" stopped being the same question
# the day a rebase entered the picture.
#
#   soak  = AUTHOR date. What soaks is the flake.lock, and a rebase does not
#           touch it: it replays the same one-line lock bump onto a cp-1
#           whose code already passed the eval gate and is already running on
#           the whole fleet. Measuring this with the committer date made the
#           judge unable to ever promote. It runs once a day and rebases
#           whenever cp-1 moved since the last run, and the rebase rewrote
#           the committer date to now -- so every merge landing before 20:00
#           reset the clock, and the 2026-09-20 bump was still in flight three
#           days later with vm-01/vm-02 permanently off cp-1 and the
#           drift monitor red every morning. Any repo where cp-1 moves more
#           than once every two days livelocks exactly like this.
#
#   push   = COMMITTER date, i.e. when the canaries could first see this
#           commit. The deploy and health graces must stay on this one: after
#           a rebase the canaries genuinely have a new closure to build, and
#           judging that rebuild against the lock's age would call a host that
#           is merely mid-build "unreachable 2880 min after the push" and roll
#           a healthy canary back.
age=$(( $(date +%s) - $(git log -1 --format=%at "$canary") ))
pushAge=$(( $(date +%s) - $(git log -1 --format=%ct "$canary") ))
log "canary $short: lock $((age / 60)) min old, pushed $((pushAge / 60)) min ago; cp-1 $(git rev-parse --short "$cp-1")"

# --- ask the canaries ---------------------------------------------------------
reasons=""; waiting=""; deployed=0
for h in $CANARIES; do
  rev=$(remote "$h" 'nixos-version --configuration-revision')
  state=$(remote "$h" 'systemctl is-system-running')
  ready=$(kubectl get node "$h" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo unknown)
  if [ -z "$rev" ]; then
    if [ "$pushAge" -ge "$DEPLOY_GRACE" ]; then reasons="$reasons
- $h: unreachable $((pushAge / 60)) min after the push"; else waiting="$waiting $h=unreachable"; fi
    continue
  fi
  if [ "$rev" != "$canary" ]; then
    if [ "$pushAge" -ge "$DEPLOY_GRACE" ]; then
      status=$(remote "$h" 'comin status 2>&1 | grep -iE "fail|error" | head -3' | tr '\n' ' ')
      reasons="$reasons
- $h: still on ${rev:0:7} $((pushAge / 60)) min after the push (comin: ${status:-no error line})"
    else
      waiting="$waiting $h=${rev:0:7}"
    fi
    continue
  fi
  deployed=$((deployed + 1))
  if [ "$state" != "running" ] || [ "$ready" != "True" ]; then
    if [ "$pushAge" -ge "$HEALTH_GRACE" ]; then reasons="$reasons
- $h: deployed but is-system-running=$state, k3s Ready=$ready"; else waiting="$waiting $h=$state/Ready=$ready"; fi
    continue
  fi
  log "$h: on $short, running, Ready"
done

# --- verdict -------------------------------------------------------------------
pr=$(gh pr list -R "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')

if [ -n "$reasons" ]; then
  log "ROLLBACK:$reasons"
  git push -q -f origin "cp-1:$BRANCH" || { echo "BROKEN: cannot reset canary"; exit 1; }
  [ -n "$pr" ] && gh pr close "$pr" -R "$REPO" -c "Canary $short rolled back by scripts/flake-canary.sh:
$reasons

Branch reset to cp-1; the canaries switch back on their own. Next Sunday's bump starts fresh." >/dev/null
  ntfy "flake canary: ROLLED BACK" urgent "canary $short reset to cp-1.$reasons"
  exit 0
fi

if [ -n "$waiting" ]; then
  log "WAIT: not all canaries there yet:$waiting"
  exit 0
fi

if [ "$age" -lt "$SOAK" ]; then
  log "WAIT: soaking, $(( (SOAK - age) / 60 )) min to go"
  exit 0
fi

if [ -z "$pr" ]; then
  log "WAIT: no open PR for $BRANCH (eval gate has nothing to report); opening one"
  gh pr create -R "$REPO" --head "$BRANCH" --base cp-1 --title "chore: weekly flake.lock update (canary)" \
    --body "Re-opened by scripts/flake-canary.sh for the eval gate." >/dev/null || true
  exit 0
fi
eval_state=$(gh pr checks "$pr" -R "$REPO" --json name,bucket --jq '[.[] | select(.name=="eval")] | .[0].bucket // "missing"' 2>/dev/null || echo unknown)
if [ "$eval_state" != "pass" ]; then
  log "WAIT: PR #$pr eval check is '$eval_state', not pass"
  exit 0
fi

log "PROMOTE: $deployed canaries healthy for $((age / 3600)) h, eval green → merging PR #$pr"
if gh pr merge "$pr" -R "$REPO" --merge; then
  git fetch -q origin
  log "cp-1 is now $(git rev-parse --short origin/cp-1); comin deploys the fleet"
  ntfy "flake canary: promoted" default "canary $short → cp-1 after $((age / 3600)) h on $CANARIES. The fleet follows; drift monitor 42 verifies tomorrow 04:40."
else
  echo "BROKEN: gh pr merge #$pr failed"
  ntfy "flake canary: merge FAILED" high "PR #$pr could not be merged by the judge; canary $short stays in flight."
  exit 1
fi
