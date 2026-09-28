#!/usr/bin/env bash
# Tests for publish-snapshots.sh — the one step that crosses the
# private->public boundary.
#
# What has to be true, and why each one is here rather than assumed:
#
#   * a checkout that is not on origin's default branch is REFUSED. This was a
#     warning until 2026-09-23 — it logged "publishing the LOCAL tree" and then
#     published it. These are SHARED checkouts: that day three of the four were
#     on feature branches, two belonging to other sessions, and running the job
#     would have pushed unmerged work to public repositories under the
#     project's name. The sanitizer still runs, so it is not a leak; it is also
#     not undoable, because a force-push does not unpublish what was fetched.
#   * --allow-local still publishes it, because the escape hatch has to exist
#     and has to be asked for by name. Cronicle's forced-command key passes no
#     arguments, so production can never take this path by accident.
#   * an unresolvable origin is refused too. Not knowing what is about to be
#     published is the case the guard exists for.
#   * a dirty tree is still refused, and behind the branch still counts as not
#     on origin — publishing stale content silently is the same failure.
#   * an unknown argument fails loudly instead of being ignored as "not
#     --dry-run", which is how the old single-argument parse behaved.
#
# Nothing leaves the machine: HOME is a fixture, the four repos are local, the
# sanitizer is a stub and every case runs --dry-run so nothing is ever pushed.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUB="$SCRIPTS/publish-snapshots.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/publishsnap-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0
say() { printf '  %-58s %s\n' "$1" "$2"; }

REPOS="nixos-iac k3s-iac cloud-01-iac cloudflare-iac"

# a fixture fleet of four repos, each with a stub sanitizer that always passes
build() {
  rm -rf "$ROOT/git" "$ROOT"/origin-*.git
  for r in $REPOS; do
    local src="$ROOT/git/ludorl82/$r"
    git init -q --bare "$ROOT/origin-$r.git"
    mkdir -p "$src/scripts"
    git init -q "$src"; git -C "$src" config user.email t@t; git -C "$src" config user.name t
    printf '#!/usr/bin/env bash\nmkdir -p "$1"; echo ok > "$1/file.txt"\n' > "$src/scripts/sanitize-public.sh"
    chmod +x "$src/scripts/sanitize-public.sh"
    echo content > "$src/README.md"
    git -C "$src" add -A; git -C "$src" commit -qm base; git -C "$src" branch -M cp-1
    git -C "$src" remote add origin "$ROOT/origin-$r.git"; git -C "$src" push -q -u origin cp-1 2>/dev/null
  done
}

run() { HOME="$ROOT" bash "$PUB" "$@" 2>&1; }

check() { # check <name> <expected rc> <grep> -- <args...>
  local name=$1 want_rc=$2 want=$3; shift 3; [ "${1:-}" = "--" ] && shift
  local out rc; out=$(run "$@"); rc=$?
  if [ "$rc" = "$want_rc" ] && grep -q -- "$want" <<<"$out"; then
    say "$name" ok; pass=$((pass+1))
  else
    say "$name" FAIL; printf '        rc=%s (attendu %s)\n        %s\n' "$rc" "$want_rc" "$(tr '\n' ' ' <<<"$out")"
    failed=$((failed+1))
  fi
}

echo "publish-snapshots.sh"

build
check "les quatre sur cp-1 -> passe" 0 "gate ok (dry run)" -- --dry-run

# THE REGRESSION: a shared checkout left on somebody's feature branch
build
git -C "$ROOT/git/ludorl82/k3s-iac" checkout -q -b une-branche-a-quelqu-un
git -C "$ROOT/git/ludorl82/k3s-iac" commit -q --allow-empty -m "travail en cours"
check "une branche de fonctionnalite -> REFUSE" 1 "k3s-iac: REFUSED (not on origin)" -- --dry-run
check "...et les autres sont quand meme traites" 1 "cloud-01-iac: gate ok" -- --dry-run
check "--allow-local passe outre, en le disant" 0 "--allow-local: publishing the LOCAL tree" -- --dry-run --allow-local

# behind origin is not on origin either: publishing stale content, silently
build
git -C "$ROOT/git/ludorl82/cloud-01-iac" commit -q --allow-empty -m "avance"
git -C "$ROOT/git/ludorl82/cloud-01-iac" push -q origin cp-1 2>/dev/null
git -C "$ROOT/git/ludorl82/cloud-01-iac" reset -q --hard HEAD~1
check "en retard sur origin -> REFUSE" 1 "cloud-01-iac: REFUSED (not on origin)" -- --dry-run

# no origin branch at all: we cannot tell what we would publish
build
git -C "$ROOT/git/ludorl82/cloudflare-iac" remote remove origin
check "origin introuvable -> REFUSE" 1 "cloudflare-iac: REFUSED (no origin branch)" -- --dry-run

# unchanged behaviour, locked in
build
echo sale > "$ROOT/git/ludorl82/nixos-iac/nouveau.txt"
check "arbre sale -> REFUSE (inchange)" 1 "nixos-iac: REFUSED (dirty tree)" -- --dry-run

build
check "argument inconnu -> echec bruyant" 2 "unknown argument" -- --dry-runn

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
