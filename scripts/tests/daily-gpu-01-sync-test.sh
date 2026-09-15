#!/usr/bin/env bash
# Tests for daily-gpu-01-sync.sh's publish_to_main.
#
# This is the one function in the job that reaches production without a person
# in the loop, so the case worth proving is the REFUSAL: dev carrying anything
# beyond the three data files must not be published by a cron that had nothing
# to do with it.
#
# `main` is a protected branch, so publishing is a pull request through `gh`,
# not a push. That half cannot be exercised against a local bare repo — so
# `gh` is stubbed and the assertions are about WHETHER it was called and with
# what. The guard in front of it, which is the part that decides, runs for real
# against throwaway repos.
#
# publish_to_main is extracted and sourced rather than the whole script run:
# it only touches git and gh, so a pair of throwaway repos plus a stub is a
# complete world for it, and a full run would start real Claude sessions.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB="$SCRIPTS/daily-gpu-01-sync.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bobsync-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }

# Lift the function out of the driver. Sourcing the driver itself would run it.
sed -n '/^publish_to_main() {/,/^}/p' "$JOB" > "$ROOT/fn.sh"
grep -q 'publish_to_main' "$ROOT/fn.sh" || { echo "could not extract publish_to_main"; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/fn.sh"

# A `gh` that records every call and obeys GH_STUB_MODE.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${GH_STUB_MODE:-ok}" in
  fail-create) [[ "$*" == *"pr create"* ]] && exit 1 ;;
  fail-merge)  [[ "$*" == *"pr merge"*  ]] && exit 1 ;;
esac
# `pr list` is asked for a number: none before a create, one after.
if [[ "$*" == *"pr list"* ]]; then
  [ -f "$GH_LOG.created" ] && echo 42
  exit 0
fi
[[ "$*" == *"pr create"* ]] && touch "$GH_LOG.created"
exit 0
STUB
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

gitq() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# world <name> — a bare remote with main and dev level, plus the SHALLOW,
# dev-only clone the job actually works in. The first version of this harness
# used a full clone, where fetching creates every remote-tracking ref — so it
# passed while the real run died on `origin/main` not existing. A fixture more
# generous than production tests nothing at the point where it is generous.
world() {
  local w="$ROOT/$1"
  mkdir -p "$w"
  git init -q --bare "$w/remote.git"
  git clone -q "$w/remote.git" "$w/seedclone" 2>/dev/null
  mkdir -p "$w/seedclone/src/data"
  echo '{}' > "$w/seedclone/src/data/architecture.json"
  echo '{}' > "$w/seedclone/src/data/dispatch.json"
  echo '{}' > "$w/seedclone/src/data/openers.json"
  echo 'x' > "$w/seedclone/README.md"
  gitq "$w/seedclone" add -A
  gitq "$w/seedclone" commit -qm seed
  gitq "$w/seedclone" push -q origin HEAD:main
  gitq "$w/seedclone" push -q origin HEAD:dev
  git clone -q --depth 1 --branch dev "$w/remote.git" "$w/site" 2>/dev/null
  echo "$w/site"
}

# advance <site> <file> <content> — one more commit on dev
advance() {
  mkdir -p "$(dirname "$1/$2")"
  echo "$3" > "$1/$2"
  gitq "$1" add -A
  gitq "$1" commit -qm "change $2"
  gitq "$1" push -q origin HEAD:dev
  gitq "$1" fetch -q origin +refs/heads/dev:refs/remotes/origin/dev
}

# fresh <name> — a world plus an empty gh log, and it sets $site.
#
# Called plainly, never as `site=$(fresh x)`: command substitution runs in a
# subshell, so the exported GH_LOG would die with it and the stub would write
# its log nowhere — which is how this was written the first time.
fresh() {
  GH_LOG="$ROOT/gh.$1"; export GH_LOG
  rm -f "$GH_LOG" "$GH_LOG.created"
  : > "$GH_LOG"
  site=$(world "$1")
}
gh_called() { [ -s "${GH_LOG:-/dev/null}" ]; }

# --------------------------------------------------------------------------
say "dev ahead by data files only: a pull request is opened and merged"
export GH_STUB_MODE=ok
fresh onlydata
advance "$site" src/data/dispatch.json '{"dispatch":"une phrase"}'
summary=(); fail=0
publish_to_main "$site"
[ "$fail" = 0 ] && ok "did not fail" || bad "did not fail"
[[ "${summary[*]}" == *"main: published"* ]] && ok "reported published" \
  || bad "reported published (got: ${summary[*]})"
grep -q "pr create" "$GH_LOG" && ok "opened a pull request" || bad "opened a pull request"
grep -q -- "--base main" "$GH_LOG" && grep -q -- "--head dev" "$GH_LOG" \
  && ok "the right direction: dev into main" || bad "the right direction: dev into main"
grep -q "pr merge" "$GH_LOG" && ok "merged it" || bad "merged it"

# --------------------------------------------------------------------------
say "a pull request is already open: it is merged, not duplicated"
export GH_STUB_MODE=ok
fresh existing
touch "$GH_LOG.created"          # pr list will now answer 42
advance "$site" src/data/openers.json '{"openers":[]}'
summary=(); fail=0
publish_to_main "$site"
[[ "${summary[*]}" == *"published (PR #42)"* ]] && ok "merged the open one" \
  || bad "merged the open one (got: ${summary[*]})"
grep -q "pr create" "$GH_LOG" && bad "did not open a second one" \
  || ok "did not open a second one"

# --------------------------------------------------------------------------
say "dev also carries other work: nothing is published at all"
export GH_STUB_MODE=ok
fresh stray
advance "$site" src/data/openers.json '{"openers":[]}'
advance "$site" src/components/LiveArchDiagram.astro '<svg>redrawn</svg>'
summary=(); fail=0
publish_to_main "$site"
[ "$fail" = 0 ] && ok "declining is not a failure" || bad "declining is not a failure"
[[ "${summary[*]}" == *"left alone"* ]] && ok "said why it declined" \
  || bad "said why it declined (got: ${summary[*]})"
[[ "${summary[*]}" == *"LiveArchDiagram"* ]] && ok "named the offending file" \
  || bad "named the offending file"
gh_called && bad "never reached gh at all" || ok "never reached gh at all"

# --------------------------------------------------------------------------
say "nothing to publish: says so, touches nothing"
export GH_STUB_MODE=ok
fresh current
summary=(); fail=0
publish_to_main "$site"
[ "$fail" = 0 ] && ok "not a failure" || bad "not a failure"
[[ "${summary[*]}" == *"already current"* ]] && ok "reported already current" \
  || bad "reported already current (got: ${summary[*]})"
gh_called && bad "never reached gh at all" || ok "never reached gh at all"

# --------------------------------------------------------------------------
say "the merge is refused: reported as a failure, loudly"
export GH_STUB_MODE=fail-merge
fresh conflict
advance "$site" src/data/dispatch.json '{"dispatch":"autre"}'
summary=(); fail=0
publish_to_main "$site"
[ "$fail" = 1 ] && ok "reported a failure" || bad "reported a failure"
[[ "${summary[*]}" == *"FAILED to merge"* ]] && ok "said the merge failed" \
  || bad "said the merge failed (got: ${summary[*]})"

# --------------------------------------------------------------------------
say "the pull request cannot even be opened: also a failure"
export GH_STUB_MODE=fail-create
fresh nopr
advance "$site" src/data/dispatch.json '{"dispatch":"encore"}'
summary=(); fail=0
publish_to_main "$site"
[ "$fail" = 1 ] && ok "reported a failure" || bad "reported a failure"
[[ "${summary[*]}" == *"FAILED to open"* ]] && ok "said it could not open one" \
  || bad "said it could not open one (got: ${summary[*]})"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$failed"
[ "$failed" = 0 ]
