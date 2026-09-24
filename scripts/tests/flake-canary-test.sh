#!/usr/bin/env bash
# Tests for flake-canary.sh — the judge that promotes or rolls back the weekly
# flake.lock canary.
#
# What has to be true, and why each one is here rather than assumed:
#
#   * a rebase does NOT restart the soak. That IS the bug this replaces. The
#     judge runs once a day and rebases whenever cp-1 moved since the last
#     run; it measured the soak with the COMMITTER date, which a rebase
#     rewrites to now. Every merge landing before 20:00 therefore reset the
#     clock, and the 2026-09-20 bump was still in flight on 2026-09-23 with
#     vm-01/vm-02 permanently off cp-1, the drift monitor red every
#     morning, and labodeludo.dev/architecture publicly showing "dérive
#     détectée". Any repo whose cp-1 moves more than once every two days
#     livelocks the same way.
#   * the deploy and health graces DO restart, and are read from the push
#     clock. This is the trap in the fix: after a rebase the canaries really
#     do have a new closure to build, so judging that rebuild against the
#     lock's age would call a host that is merely mid-build "unreachable
#     2880 min after the push" and roll a healthy canary back.
#   * a canary that is genuinely late still rolls back, so the fix does not
#     buy quiet by making the judge blind.
#
# Nothing leaves the machine and no fleet is touched: the "remote" is a local
# bare repository so the real git codepaths run for real, and ssh/gh/kubectl
# are stubs injected through FLAKE_CANARY_PATH_PREFIX.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JUDGE="$SCRIPTS/flake-canary.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/flakecanary-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '  %-58s %s\n' "$1" "$2"; }
ok()   { say "$1" "ok"; pass=$((pass+1)); }
bad()  { say "$1" "FAIL"; printf '        %s\n' "$2"; failed=$((failed+1)); }

# --- stubs ------------------------------------------------------------------
# `remote` runs: ssh BASTION "ssh HOST 'CMD'". The stub only has to answer the
# two commands the judge asks for, and it reads what to answer from files so
# each scenario can pose a different fleet.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *configuration-revision*) cat "$STUB_REV"; exit 0;;
                               *is-system-running*)      cat "$STUB_STATE"; exit 0;; esac; done
exit 0
EOF
cat > "$ROOT/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_READY"
EOF
# The judge asks gh for an open PR, then for its eval check, then merges it.
cat > "$ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "pr list"*)   echo 7 ;;
  "pr checks"*) echo pass ;;
  "pr merge"*)  echo merged >> "$STUB_MERGED"; exit 0 ;;
  "pr close"*)  echo closed >> "$STUB_MERGED"; exit 0 ;;
  "pr create"*) exit 0 ;;
esac
EOF
chmod +x "$ROOT/bin/"*

# --- a repo whose canary carries one lock bump ------------------------------
# lock_age / push_age are seconds; they become the commit's author and
# committer dates, which is exactly the distinction under test.
build_repo() { # build_repo <lock_age_s> <push_age_s>
  rm -rf "$ROOT/origin.git" "$ROOT/seed" "$ROOT/home"
  mkdir -p "$ROOT/home/.iac-updates"
  git init -q --bare "$ROOT/origin.git"
  git init -q "$ROOT/seed" && cd "$ROOT/seed"
  git config user.email t@t && git config user.name t
  echo base > flake.lock && git add . && git commit -qm base
  git branch -M cp-1
  git remote add origin "$ROOT/origin.git" && git push -q -u origin cp-1
  # the lock bump, authored <lock_age> ago and committed <push_age> ago
  git checkout -q -b canary
  echo bumped > flake.lock && git add .
  GIT_AUTHOR_DATE="$(date -d "@$(( $(date +%s) - $1 ))" -Iseconds)" \
  GIT_COMMITTER_DATE="$(date -d "@$(( $(date +%s) - $2 ))" -Iseconds)" \
    git commit -qm "chore: weekly flake.lock update"
  git push -q -u origin canary
  CANARY_SHA=$(git rev-parse HEAD)
  cd - >/dev/null
  git clone -q "$ROOT/origin.git" "$ROOT/home/.iac-updates/nixos-iac"
}

run_judge() { # run_judge -> prints the judge's log
  HOME="$ROOT/home" \
  FLAKE_CANARY_PATH_PREFIX="$ROOT/bin" \
  CANARIES="vm-01 vm-02" BASTION=jumphost \
  SOAK=86400 DEPLOY_GRACE=7200 HEALTH_GRACE=3600 \
  STUB_REV="$ROOT/rev" STUB_STATE="$ROOT/state" STUB_READY="$ROOT/ready" \
  STUB_MERGED="$ROOT/merged" \
    bash "$JUDGE" 2>&1
}

fleet() { # fleet <revision> <systemd state> <k8s ready>
  printf '%s\n' "$1" > "$ROOT/rev"
  printf '%s\n' "$2" > "$ROOT/state"
  printf '%s\n' "$3" > "$ROOT/ready"
  : > "$ROOT/merged"
}

echo "flake-canary.sh"

# 1. THE REGRESSION. The lock was pushed two days ago and rebased an hour ago;
#    cp-1 has not moved since, both canaries are on it and healthy.
build_repo $((48*3600)) 3600
fleet "$CANARY_SHA" running True
out=$(run_judge)
if grep -q "^\[.*PROMOTE" <<<"$out" && grep -q merged "$ROOT/merged"; then
  ok "rebased canary, lock 48 h old -> PROMOTE"
else
  bad "rebased canary, lock 48 h old -> PROMOTE" "$(tr '\n' ' ' <<<"$out")"
fi

# 2. A lock that really is young still soaks.
build_repo 3600 3600
fleet "$CANARY_SHA" running True
out=$(run_judge)
grep -q "WAIT: soaking" <<<"$out" \
  && ok "fresh lock -> WAIT: soaking" \
  || bad "fresh lock -> WAIT: soaking" "$(tr '\n' ' ' <<<"$out")"

# 3. THE TRAP. Old lock, but the commit was pushed ten minutes ago and a canary
#    has not switched yet. That is a build in progress, not a dead host.
build_repo $((48*3600)) 600
fleet "somethingelse" running True
out=$(run_judge)
if grep -q "WAIT: not all canaries there yet" <<<"$out" && ! grep -q ROLLBACK <<<"$out"; then
  ok "old lock, pushed 10 min ago, canary mid-build -> WAIT"
else
  bad "old lock, pushed 10 min ago, canary mid-build -> WAIT" "$(tr '\n' ' ' <<<"$out")"
fi

# 4. Past the deploy grace it is a dead host, and the judge still says so.
build_repo $((48*3600)) $((3*3600))
fleet "somethingelse" running True
out=$(run_judge)
grep -q "ROLLBACK" <<<"$out" \
  && ok "old lock, pushed 3 h ago, canary still behind -> ROLLBACK" \
  || bad "old lock, pushed 3 h ago, canary still behind -> ROLLBACK" "$(tr '\n' ' ' <<<"$out")"

# 5. Deployed but unhealthy past the health grace -> rollback, not promote.
build_repo $((48*3600)) $((3*3600))
fleet "$CANARY_SHA" degraded False
out=$(run_judge)
grep -q "ROLLBACK" <<<"$out" \
  && ok "deployed but degraded past the grace -> ROLLBACK" \
  || bad "deployed but degraded past the grace -> ROLLBACK" "$(tr '\n' ' ' <<<"$out")"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
