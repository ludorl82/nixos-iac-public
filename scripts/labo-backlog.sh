#!/usr/bin/env bash
# labo-backlog — la SEULE écriture permise à l'observateur (OpenCode) : proposer une entrée
# au backlog du labo (net-cfgs/backlog.md), que Ludo et Claude traiteront.
#
#   labo-backlog "Titre court" ["détails, une ou plusieurs phrases"]
#
# L'entrée va dans la section « Proposé par l'observateur » (créée au besoin, juste
# avant « ## Articles »), datée et signée, puis commit + push sur cp-1 —
# net-cfgs se commite directement sur cp-1. Clone DÉDIÉ
# (~/.local/share/qwen-voice/net-cfgs) : la copie de travail partagée des
# sessions Claude n'est jamais touchée. Titre et détails : du texte, rien
# d'autre ; pas de lien, pas de code.
set -uo pipefail
REPO_URL="${LABO_BACKLOG_REPO:-git@github.com:ludorl82/net-cfgs.git}"
CLONE="${LABO_BACKLOG_CLONE:-$HOME/.local/share/qwen-voice/net-cfgs}"
SECTION="### Proposé par l'observateur"

die() { echo "labo-backlog : $*" >&2; exit 1; }
title=${1:-}; details=${2:-}
[ -n "$title" ] || die 'usage : labo-backlog "Titre court" ["détails"]'
[ ${#title} -le 120 ] || die "titre trop long (120 caractères max)"
[ ${#details} -le 1500 ] || die "détails trop longs (1500 caractères max)"
case "$title$details" in *$'\n\n'*|*'```'*|*'<'*|*'`'*) die "texte seulement : pas de bloc de code, de balise ni de paragraphe vide";; esac

if [ ! -d "$CLONE/.git" ]; then
  git clone -q "$REPO_URL" "$CLONE" || die "clone impossible"
fi
cd "$CLONE" || die "clone introuvable"
git config user.name "Observateur (assistant du bureau)"
git config user.email "observateur@labo.invalid"

for attempt in 1 2 3; do
  git fetch -q origin cp-1 && git reset -q --hard origin/cp-1 || die "fetch impossible"
  python3 - "$title" "$details" "$SECTION" <<'PY' || exit 1
import datetime, sys, textwrap
title, details, section = sys.argv[1], sys.argv[2], sys.argv[3]
p = "backlog.md"; s = open(p, encoding="utf-8").read()
today = datetime.date.today().isoformat()
body = f"- **{title}** _(proposé par l'observateur, {today})_"
if details.strip():
    body += "\n" + textwrap.indent(textwrap.fill(" ".join(details.split()), 76), "  ")
if section not in s:
    anchor = "\n## Articles"
    if anchor not in s:
        sys.exit("labo-backlog : section « ## Articles » introuvable, structure inattendue")
    intro = (f"\n{section}\n\nIdées et constats notés par l'observateur, l'assistant du bureau, qui lit le labo "
             "sans le modifier. À trier : garder, reformuler ou supprimer.\n\n")
    s = s.replace(anchor, intro + body + "\n" + anchor, 1)
else:
    i = s.index(section)
    j = s.find("\n## ", i + len(section))
    k = s.find("\n### ", i + len(section))
    end = min(x for x in (j, k, len(s)) if x != -1)
    s = s[:end].rstrip("\n") + "\n\n" + body + "\n" + s[end:]
open(p, "w", encoding="utf-8").write(s)
PY
  git add backlog.md
  git commit -q -m "backlog (observateur) : $title" || die "rien à commiter"
  if git push -q origin HEAD:cp-1 2>/dev/null; then
    echo "Ajouté au backlog ($(git rev-parse --short HEAD)) : $title"
    exit 0
  fi
  sleep $((attempt * 2))   # someone pushed meanwhile: redo on the new tip
done
die "push refusé trois fois"
