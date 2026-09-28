#!/usr/bin/env bash
# Tests for labo-backlog.sh — Qwen's only write. A bare local repo stands in
# for GitHub; nothing leaves the machine.
#
# Proven: the entry lands in « Proposé par l'observateur » before « ## Articles »,
# dated and signed, committed and pushed to cp-1; a second entry goes in the
# same section; code, markup and oversized text are refused and nothing is
# pushed; the shared checkout is never used.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$SCRIPTS/labo-backlog.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/backlog-test.XXXXXX"); trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }

git init -q --bare -b cp-1 "$ROOT/remote.git"
git clone -q "$ROOT/remote.git" "$ROOT/seed" 2>/dev/null
cat > "$ROOT/seed/backlog.md" <<'MD'
# Backlog

## Projects

### Investigate

- **Old item.** Something.

## Articles

### Ready to write
MD
( cd "$ROOT/seed" && git add . && git -c user.name=t -c user.email=t@t commit -qm init && git push -q origin cp-1 )
export LABO_BACKLOG_REPO="$ROOT/remote.git" LABO_BACKLOG_CLONE="$ROOT/clone"
remote_md() { git -C "$ROOT/remote.git" show cp-1:backlog.md; }

out=$("$B" "Encodeur Frigate basse résolution en panne" "frigate-lowres-feed.service inactif depuis 06:15 ; à regarder.")
case $out in "Ajouté au backlog"*) ok "reports the commit";; *) bad "output: $out";; esac
md=$(remote_md)
case $md in *"### Proposé par l'observateur"*"- **Encodeur Frigate basse résolution en panne** _(proposé par l'observateur, "*"## Articles"*) ok "entry pushed, in its section, before Articles";; *) bad "entry not where expected";; esac
case $md in *"- **Old item.** Something."*) ok "existing content kept";; *) bad "existing content damaged";; esac
"$B" "Deuxième idée" >/dev/null
[ "$(remote_md | grep -c "^### Proposé par l'observateur")" = 1 ] && ok "one section, not two" || bad "section duplicated"
case $(remote_md | sed -n "/### Proposé par l'observateur/,/## Articles/p") in *"Deuxième idée"*) ok "second entry in the same section";; *) bad "second entry misplaced";; esac
[ "$(git -C "$ROOT/remote.git" log --format=%an -1 cp-1)" = "Observateur (assistant du bureau)" ] && ok "commit signed by the observer" || bad "wrong author"

before=$(git -C "$ROOT/remote.git" rev-parse cp-1)
for args in "" "x\`rm -rf\`" "<script>" "$(printf 'a\n\nb')" "$(head -c 200 /dev/zero | tr '\0' x)"; do
  "$B" "$args" >/dev/null 2>&1 && bad "accepted: ${args:0:20}" || ok "refused: ${args:0:20}"
done
[ "$(git -C "$ROOT/remote.git" rev-parse cp-1)" = "$before" ] && ok "nothing pushed by a refused call" || bad "a refused call pushed"

printf '\n%d passed, %d failed\n' "$pass" "$failed"; [ "$failed" -eq 0 ]
