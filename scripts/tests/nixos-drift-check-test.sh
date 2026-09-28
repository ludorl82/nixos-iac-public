#!/usr/bin/env bash
# Tests for nixos-drift-check.sh — when a canary is allowed to differ.
#
# What has to be true, and why each one is here rather than assumed:
#
#   * a canary branch AHEAD of cp-1 excuses the canary hosts. That is the
#     whole exception: comin deploys the testing branch to them on purpose.
#   * a canary branch BEHIND cp-1 excuses nothing. The first version granted
#     the exception whenever the two refs merely differed, and the branch
#     trails cp-1 most of the time — the judge resets it onto cp-1, the
#     next merge leaves it behind. On 2026-09-25 the log said "canary in
#     flight 4c2d437" about an ordinary cp-1 merge two commits old; a canary
#     host stuck there would have read "ok (canary)" instead of STALE.
#   * no canary branch, or one equal to cp-1, is the quiet case.
#   * the ancestry check never touches the checkout it runs from. It fetches
#     history, and a shallow fetch into a full clone makes it shallow.
#
# Nothing leaves the machine: the remote is a local bare repository and ssh is
# a stub that answers each host's revision from STUB_REVS. It runs the REAL
# script against the REAL hosts/ directory, so the canary and on-demand
# declarations are the ones in the repo.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS/.." && pwd)"
CHECK="$SCRIPTS/nixos-drift-check.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/driftcheck-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0
say() { printf '  %-60s %s\n' "$1" "$2"; }

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
host=""; for a in "$@"; do case "$a" in driftcheck@*) host=${a#driftcheck@}; host=${host%%.*};; esac; done
last="${!#}"
[ "$last" = gpus ] && exit 1                     # gpu probe: "did not answer"
for kv in $STUB_REVS; do [ "${kv%%=*}" = "$host" ] && { echo "${kv#*=}"; exit 0; }; done
[ -n "${STUB_OFF:-}" ] && case " $STUB_OFF " in *" $host "*) exit 255;; esac
echo "$STUB_DEFAULT"
EOF
chmod +x "$ROOT/bin/ssh"

# a remote with cp-1 = M, and whatever canary the case needs
new_remote() {
  rm -rf "$ROOT/remote.git" "$ROOT/seed"
  git init -q --bare "$ROOT/remote.git"
  git init -q "$ROOT/seed"; git -C "$ROOT/seed" config user.email t@t; git -C "$ROOT/seed" config user.name t
  echo a > "$ROOT/seed/f"; git -C "$ROOT/seed" add f; git -C "$ROOT/seed" commit -qm M
  git -C "$ROOT/seed" branch -M cp-1
  git -C "$ROOT/seed" remote add origin "$ROOT/remote.git"; git -C "$ROOT/seed" push -q origin cp-1 2>/dev/null
  M=$(git -C "$ROOT/seed" rev-parse HEAD)
}

run() { # run <name> <expected rc> <grep1> <grep2>   (uses STUB_* from caller)
  local out rc
  out=$(PATH="$ROOT/bin:$PATH" DRIFT_REMOTE="$ROOT/remote.git" KUMA_PUSH_URL="" \
        DRIFT_KEY=/dev/null STUB_REVS="$STUB_REVS" STUB_DEFAULT="$STUB_DEFAULT" STUB_OFF="arcade1 arcade2" \
        sh "$CHECK" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && grep -q -- "$3" <<<"$out" && grep -q -- "$4" <<<"$out"; then
    say "$1" ok; pass=$((pass+1))
  else
    say "$1" FAIL; printf '        rc=%s (attendu %s)\n' "$rc" "$2"
    grep -E "^drift|vm-01|vm-02|drift-revisions" <<<"$out" | sed 's/^/        /'
    failed=$((failed+1))
  fi
}

echo "nixos-drift-check.sh"

# 1. canary AHEAD: cp-1 + one lock commit, canaries deployed it
new_remote
git -C "$ROOT/seed" checkout -q -b canary; echo lock > "$ROOT/seed/flake.lock"
git -C "$ROOT/seed" add flake.lock; git -C "$ROOT/seed" commit -qm "lock bump"
git -C "$ROOT/seed" push -q origin canary 2>/dev/null; C=$(git -C "$ROOT/seed" rev-parse HEAD)
STUB_REVS="vm-01=$C vm-02=$C"; STUB_DEFAULT=$M
run "canari EN AVANCE, canaris dessus -> vert" 0 "(ahead of cp-1)" "vm-01: ok (canary)"

# 2. THE BUG: canary BEHIND cp-1, a canary host stuck on that old commit
new_remote; OLD=$M
git -C "$ROOT/seed" push -q origin cp-1:canary 2>/dev/null
echo b >> "$ROOT/seed/f"; git -C "$ROOT/seed" commit -qam "un merge de plus"; git -C "$ROOT/seed" push -q origin cp-1 2>/dev/null
M=$(git -C "$ROOT/seed" rev-parse HEAD)
STUB_REVS="vm-01=$OLD"; STUB_DEFAULT=$M
run "canari EN RETARD, canari coince dessus -> STALE" 1 "NOT ahead of cp-1" "vm-01: STALE"

# 3. no canary branch
new_remote; STUB_REVS=""; STUB_DEFAULT=$M
run "pas de branche canary -> vert" 0 "no canary in flight" "vm-01: ok"

# 4. canary equal to cp-1
new_remote; git -C "$ROOT/seed" push -q origin cp-1:canary 2>/dev/null; STUB_REVS=""; STUB_DEFAULT=$M
run "canary = cp-1 -> vert" 0 "no canary in flight" "vm-02: ok"

# 5. the checkout the script lives in is untouched
if [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository)" = false ] \
   && ! git -C "$REPO_ROOT" show-ref -q refs/m refs/c 2>/dev/null; then
  say "le checkout n'a pas ete touche (ni superficiel, ni refs/m, refs/c)" ok; pass=$((pass+1))
else
  say "le checkout n'a pas ete touche" FAIL; failed=$((failed+1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
