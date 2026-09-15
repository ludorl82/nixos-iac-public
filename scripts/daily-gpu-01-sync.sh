#!/usr/bin/env bash
# Daily — what gpu-01 knows, refreshed every morning.
#
# Two deliverables, both small, both public-only:
#
#   Session E — the dispatch: one line about what moved in the fleet since
#     yesterday, so "quoi de neuf ?" has an answer that is actually new.
#   Session F — the suggested questions: four real ones people asked, chosen
#     from a counted list and published verbatim or not at all.
#
# Both go through scripts/ask-local.py — one call, the gate, two corrections —
# on the lab's own model from 2026-09-09 to 2026-09-13, and on qwen3.8-flash
# (Alibaba Cloud Model Studio) since, at a few cents a day. Both tasks are
# bounded, both outputs are short, and both are judged by a deterministic gate
# that is never relaxed to fit the model — if it drifts, the job goes red
# instead of publishing.
#
# WHY THIS IS A SEPARATE SCRIPT (2026-09-07). Both used to live inside
# nightly-diagram-sync.sh's session B. That job is WEEKLY on purpose — Sunday
# 04:45 — because redrawing the architecture and the racks every night was
# expensive for drawings that rarely change. Neither of these draws anything:
# E is a computed diff plus a sentence, F is a selection from a list. Riding
# along on the redraw meant a "dépêche de la nuit" that was rewritten once a
# week, so six mornings out of seven gpu-01 answered "what's new?" with news from
# up to six days ago. The cadence belonged to the drawings, not to these.
#
# WHY IT COMMITS architecture.json. The daily chain refreshes that data in CI
# — architecture.yml joins the public snapshots, stamps the drift badge and
# deploys — but deliberately does NOT commit; the committed copy is only a
# fallback for a build that cannot reach the snapshots. The dispatch needs a
# yesterday to compare against, and the committed copy IS that yesterday, so
# something has to move it forward daily or the diff is against last Sunday.
# This job does, which also stops the fallback from sitting a week stale.
#
# Public-only, entirely. It clones the four PUBLIC snapshots and the site, and
# never reads a private repo — so unlike the weekly job there is no
# private/public boundary to police here, and no fleet seed to carry across.
# scan-public.py still runs on both deliverables: the gate is cheap and the
# session that writes prose is exactly where a leak would come from.
#
# Honesty: Kuma push at the end so a silent morning still beats a dead job
# (the monitor fires on ABSENCE), ntfy only when something changed or failed,
# non-zero exit so Cronicle shows red.
set -euo pipefail

# Same reason as the weekly job: bash reads a script by byte offset, so
# overwriting this file mid-run would resume inside the new content. Re-exec
# from an immutable snapshot and a deploy during a run is harmless.
if [ "${BOB_SYNC_SNAPSHOT:-}" != "1" ]; then
  snap=$(mktemp /tmp/daily-gpu-01-sync.XXXXXX.sh)
  cat "$0" > "$snap"
  chmod +x "$snap"
  # Where the REAL script lives, remembered before the re-exec swaps $0 for the
  # snapshot in /tmp. ask-local.py sits beside it, and `dirname "$0"` after the
  # re-exec would look for it in /tmp and find nothing.
  BOB_SYNC_DIR="$(cd "$(dirname "$0")" && pwd)" \
    BOB_SYNC_SNAPSHOT=1 exec "$snap" "$@"
fi
SCRIPT_DIR="${BOB_SYNC_DIR:-$(cd "$(dirname "$0")" && pwd)}"

export PATH="$HOME/.local/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

PUBLIC_REPOS=(nixos-iac-public k3s-iac-public cloud-01-iac-public cloudflare-iac-public)
LOG_PREFIX="daily-gpu-01-sync"
# Its own push monitor, not the weekly job's: sharing one would mean a dead
# daily job looks alive every Sunday. URL kept out of the repo, same
# imperative-console-state convention as the ntfy token.
KUMA_PUSH_URL="${KUMA_PUSH_URL:-$(cat "$HOME/.config/kuma-gpu-01-sync-push" 2>/dev/null || true)}"
NTFY_URL="https://ntfy.lab.example/alerts"
NTFY_TOKEN=$(cat "$HOME/.config/ntfy-diagram-sync-token" 2>/dev/null || true)
POPULAR_TOKEN="$HOME/.config/gpu-01-popular-token"
# E and F run on a hosted model since 2026-09-13 (ask-local.py, ASK_BACKEND
# openai, qwen3.8-flash on Alibaba Cloud Model Studio). The local 35B did the
# job for four days and then chose, as a suggested question, the false-premise
# example its own prompt names — the one judgement the gates cannot make. The
# site's privacy policy says what this sends where: the counted list of
# visitor questions (F) and a computed fleet diff (E). Key from KeePass, in the
# environment of the python process only. ASK_BACKEND=ollama = the old path.
ASK_BACKEND="${ASK_BACKEND:-openai}"
ASK_API_KEY="${ASK_API_KEY:-}"
if [ "$ASK_BACKEND" = openai ] && [ -z "$ASK_API_KEY" ]; then
  ASK_API_KEY=$(ssh -o BatchMode=yes console-vm 'kp-get "Alibaba Cloud API Key"' 2>/dev/null || true)
fi
if [ "$ASK_BACKEND" = openai ] && [ -z "$ASK_API_KEY" ]; then
  echo "daily-gpu-01-sync: no Model Studio API key (KeePass « Alibaba Cloud API Key »)" >&2
  exit 1
fi
export ASK_BACKEND ASK_API_KEY

summary=()
fail=0
dispatch_published=0
openers_published=0
arch_moved=0

log() { echo "$LOG_PREFIX: $*"; }

notify() { # notify <title> <body>
  [ -n "$NTFY_TOKEN" ] || { log "no ntfy token — skipping notify"; return 0; }
  curl -fsS --max-time 10 -H "Authorization: Bearer $NTFY_TOKEN" \
    -H "Title: $1" -d "$2" "$NTFY_URL" >/dev/null 2>&1 \
    || log "ntfy notify failed (non-fatal)"
}

kuma() { # kuma <up|down> <msg>
  [ -n "$KUMA_PUSH_URL" ] || { log "no kuma push url — skipping heartbeat"; return 0; }
  curl -fsS --max-time 10 -G "$KUMA_PUSH_URL" \
    --data-urlencode "status=$1" --data-urlencode "msg=$2" >/dev/null 2>&1 \
    || log "kuma push failed (non-fatal)"
}

# --------------------------------------------------------------------------
# Session E — the dispatch
# --------------------------------------------------------------------------
#
# The model does not compute the diff, it phrases it. dispatch-diff.py hands
# it a list of what changed, and check-dispatch.py then refuses any machine
# name that is not on that list — so the one place a hallucination could
# enter is the one place with a mechanical gate in front of it.
run_dispatch() {
  local scratch="$1"
  local site="$scratch/site"

  if [ ! -s "$scratch/architecture.prev.json" ]; then
    summary+=("E: skipped (no previous topology to compare)")
    return 0
  fi

  local work="$scratch/dispatch"
  mkdir -p "$work"
  python3 "$site/scripts/topology/dispatch-diff.py" \
    "$scratch/architecture.prev.json" "$site/src/data/architecture.json" \
    > "$work/diff.json" || { summary+=("E: diff failed"); fail=1; return 0; }

  # The common case, and it costs nothing: no session is started at all.
  if [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['empty'])" "$work/diff.json")" = "True" ]; then
    summary+=("E: quiet night (fleet unchanged)")
    return 0
  fi

  # The lab's own model since 2026-09-09, not a hosted one. Measured against
  # this very gate first: 20/20 on the first attempt over twenty trials. The
  # task is what makes that safe — a diff computed upstream, one sentence out,
  # and check-dispatch.py refusing any name or any number the diff does not
  # contain. ask-local.py does one call, runs the gate, and allows exactly one
  # correction, which is the shape the prompt already prescribed.
  python3 "$SCRIPT_DIR/ask-local.py" \
      --prompt "$site/scripts/topology/prompts/dispatch.md" \
      --out "$work/dispatch.json" \
      --attach diff.json="$work/diff.json" \
      -- python3 "$site/scripts/topology/check-dispatch.py" '$OUT' "$work/diff.json" \
    || { summary+=("E: local model failed"); fail=1; return 0; }

  [ -s "$work/dispatch.json" ] || { summary+=("E: wrote no dispatch"); fail=1; return 0; }

  # Both gates, in the order that matters: truthful first (it names only what
  # changed), then public (it leaks nothing). Either refusal drops the line —
  # a wrong dispatch is worse than no dispatch, because gpu-01 would say it.
  python3 "$site/scripts/topology/check-dispatch.py" "$work/dispatch.json" "$work/diff.json" \
    || { summary+=("E: REFUSED by check-dispatch"); fail=1; return 0; }
  python3 "$site/scripts/topology/scan-public.py" "$work/dispatch.json" \
    || { summary+=("E: REFUSED by scan-public"); fail=1; return 0; }

  # The driver stamps the time: the session has no clock it can trust.
  python3 - "$work/dispatch.json" "$site/src/data/dispatch.json" "$(date -u +%FT%TZ)" <<'PYDISPATCH'
import json, sys
d = json.load(open(sys.argv[1]))
out = {
    "counts": d.get("counts", {}),
    "dispatch": d.get("dispatch", "").strip(),
    "generated": sys.argv[3],
}
json.dump(out, open(sys.argv[2], "w"), indent=2, sort_keys=True, ensure_ascii=False)
open(sys.argv[2], "a").write("\n")
PYDISPATCH
  dispatch_published=1
  summary+=("E: dispatch written")
}

# --------------------------------------------------------------------------
# Session F — the suggested questions, chosen from real ones
# --------------------------------------------------------------------------
#
# The Worker counts (no IP, no session, address-shaped input never stored),
# this session SELECTS, and check-openers.py refuses anything that is not
# verbatim in the candidate list. A question nobody asked cannot reach the
# page, and neither can a real one with a word changed. Nothing here writes
# live: it lands as a commit, which is the actual moderation.
run_openers() {
  local scratch="$1"
  local site="$scratch/site"

  [ -s "$POPULAR_TOKEN" ] || { summary+=("F: skipped (no popular-questions token)"); return 0; }

  local work="$scratch/openers"
  mkdir -p "$work"
  if ! curl -fsS --max-time 20 -H "Authorization: Bearer $(cat "$POPULAR_TOKEN")" \
       https://labodeludo.dev/api/gpu-01/popular > "$work/candidates.json"; then
    summary+=("F: could not read the candidates")
    fail=1; return 0
  fi

  # Hand the model ONLY the candidates the gate could accept. On 2026-09-13
  # the most-asked question was 74 characters long; the model picked it (it
  # was the obvious pick), the gate refused it for length, the one retry
  # re-picked it without its accents, and the chained job went red three
  # times in a day over a question that could never have been published.
  # Shape is deterministic — length, the question mark, no address — so it
  # is decided here, with the gate's own constants, before any model call.
  # The final gate still checks against the FULL list (verbatim, unchanged).
  local n
  n=$(python3 - "$work/candidates.json" "$work/eligible.json" "$site/scripts/topology/check-openers.py" <<'PY' 2>/dev/null || echo 0
import importlib.util, json, sys
src, dst, gate = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("gate", gate)
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
d = json.load(open(src))
# the same record shape the gate reads: {"n": count, "text": question}
ok = [c for c in d.get("candidates", []) if isinstance(c, dict) and "text" in c
      and g.MIN_LEN <= len(c["text"]) <= g.MAX_LEN
      and c["text"].rstrip().endswith("?")
      and not g.ADDRESSY.search(c["text"])]
json.dump({**d, "candidates": ok}, open(dst, "w"), ensure_ascii=False)
print(len(ok))
PY
)
  if [ "$n" = 0 ]; then
    summary+=("F: no eligible question asked lately")
    return 0
  fi

  # Edit as well as Write: both prompts end with "run the gate yourself and
  # fix what it refuses", and on 2026-09-07 this session did exactly that —
  # picked "c quoi ton nom", saw check-openers refuse it for not being a
  # question, and then stopped to ask for write permission it had not been
  # given. A session told to correct itself needs the tool to do it.
  # Local too, and this is the session where that needed proving rather than
  # assuming: it is the only place a stranger's words get published. Rehearsed
  # on 2026-09-08 with six hostile candidates mixed into the real list —
  # including three check-openers.py cannot catch, a job pitch, an off-topic
  # question and a request for a personal address — and none was published in
  # 35 trials. When it does fail it fails on the side the gate catches: it
  # tidied a typo, which the verbatim rule forbids and the gate refused.
  python3 "$SCRIPT_DIR/ask-local.py" \
      --prompt "$site/scripts/topology/prompts/openers.md" \
      --out "$work/openers.json" \
      --attach candidates.json="$work/eligible.json" \
      -- python3 "$site/scripts/topology/check-openers.py" '$OUT' "$work/candidates.json" \
    || { summary+=("F: local model failed"); fail=1; return 0; }

  [ -s "$work/openers.json" ] || { summary+=("F: chose nothing"); return 0; }

  # Publish the candidate's OWN spelling. The hosted model capitalises a first
  # letter and the gate now tolerates that; what goes on the button is still
  # the visitor's text, character for character.
  python3 - "$work/openers.json" "$work/candidates.json" <<'PYCANON'
import json, sys
o = json.load(open(sys.argv[1])); c = json.load(open(sys.argv[2])).get("candidates", [])
exact = {x["text"].casefold(): x["text"] for x in c if isinstance(x, dict) and "text" in x}
o["openers"] = [exact.get(q.casefold(), q) for q in o.get("openers", [])]
json.dump(o, open(sys.argv[1], "w"), ensure_ascii=False)
PYCANON

  python3 "$site/scripts/topology/check-openers.py" "$work/openers.json" "$work/candidates.json" \
    || { summary+=("F: REFUSED by check-openers"); fail=1; return 0; }
  python3 "$site/scripts/topology/scan-public.py" "$work/openers.json" \
    || { summary+=("F: REFUSED by scan-public"); fail=1; return 0; }

  # The gates above prove a stranger really asked this, verbatim. None of them
  # can prove gpu-01 has anything to say about it — and on 2026-09-15 the panel
  # was offering « T'as un article sur Proxmox ? », which production answers
  # « ça, c'est pas documenté ». A suggestion that leads to a refusal is the
  # worst thing this panel can produce: the visitor pressed the site's own
  # button and hit a dead end.
  #
  # So ask him. This one FILTERS rather than fails: a dead end is a quality
  # problem, not a safety one, and dropping it while publishing the rest beats
  # turning the whole job red. It keeps a question it could not check — see
  # its docstring — so a broken endpoint shows up as a smaller panel and a
  # number in the summary, never as silent deletion.
  #
  # It is the slow step by design: ~6 s between questions, because the rate
  # limiter is per-IP and the first run of it turned its own batch into 429s.
  local kept_note=""
  if kept_note=$(python3 "$site/scripts/topology/check-answerable.py" \
                   "$work/openers.json" --filter --min 1 2>&1 | tail -1); then
    summary+=("F: $kept_note")
  else
    summary+=("F: nothing answerable survived ($kept_note)")
    return 0
  fi

  python3 - "$work/openers.json" "$site/src/data/openers.json" "$(date -u +%FT%TZ)" <<'PYOPENERS'
import json, sys
d = json.load(open(sys.argv[1]))
out = {"generated": sys.argv[3], "openers": d.get("openers", [])}
json.dump(out, open(sys.argv[2], "w"), indent=2, sort_keys=True, ensure_ascii=False)
open(sys.argv[2], "a").write("\n")
PYOPENERS
  openers_published=1
  summary+=("F: $(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['openers']))" "$work/openers.json") suggested question(s)")
}

# --------------------------------------------------------------------------
# Publishing to main
# --------------------------------------------------------------------------
#
# These files reach a visitor only from `main`: prod builds from it, and the
# Worker fetches gpu-01's grounding from the prod origin whatever host was
# called. Until 2026-09-07 both deliverables stopped on `dev` and waited for
# someone to merge — which meant that in the whole life of the feature, the
# dispatch and the suggested questions had never once been published. The
# weekly job had the same gap; nobody noticed because nobody looked at prod
# for a line that was only ever written to a branch.
#
# So this fast-forwards main, but ONLY when the entire difference between the
# two branches is the three data files. That buys two things:
#
#   * unrelated work parked on `dev` is never dragged into production by a job
#     that had nothing to do with it;
#   * a redraw from the weekly job blocks the merge and keeps the human look
#     it deserves — a drawing is not a data file.
#
# The moderation argument for the suggested questions was "the commit is small
# enough to read". That is weaker now, and worth stating plainly: what still
# stands between a stranger's words and the page is the ingest filter, the
# verbatim gate, scan-public, and a session told to reject anything that is
# not a question about this homelab. What no longer stands there is a person,
# unless they read the commit afterwards.
#
# Fast-forward only. A rejected push means main holds commits dev does not,
# and untangling that is a person's job, not a cron's.
publish_to_main() {
  local site="$1"
  # The refspec is load-bearing. `git fetch origin main` fetches the commit but
  # writes only FETCH_HEAD — it does NOT create refs/remotes/origin/main — so
  # the diff below died with "ambiguous argument", and under `set -e` that took
  # the whole job down after it had already pushed to dev (2026-09-07, first
  # live run of this function). The first test suite missed it because its fake
  # world used a full clone, where the default refspec creates every tracking
  # ref; the real clone is `--depth 1 --branch dev` and has exactly one.
  git -C "$site" fetch -q origin +refs/heads/main:refs/remotes/origin/main 2>/dev/null \
    || { summary+=("main: cannot fetch"); fail=1; return 0; }

  # Two-dot on purpose: it compares the two tips, which is exactly "what would
  # change in main". A three-dot diff needs the merge base, and this clone is
  # shallow, so it does not have one.
  local files stray
  files=$(git -C "$site" diff --name-only origin/main..origin/dev) \
    || { summary+=("main: cannot compare"); fail=1; return 0; }
  [ -n "${files// /}" ] || { summary+=("main: already current"); return 0; }

  stray=$(grep -v -e '^src/data/architecture\.json$' \
                 -e '^src/data/dispatch\.json$' \
                 -e '^src/data/openers\.json$' <<<"$files" || true)
  if [ -n "${stray// /}" ]; then
    summary+=("main: left alone (dev carries other work: $(tr '\n' ' ' <<<"$stray"))")
    return 0
  fi

  # `main` is a PROTECTED branch — "changes must be made through a pull
  # request", with enforce_admins on — so no push can ever land there, fast
  # forward or not. Two earlier attempts failed for two different wrong
  # reasons before the third error message said this one plainly.
  #
  # The protection asks for a pull request, not for a human: zero approvals
  # are required and there are no required checks. So the job takes the same
  # path a person does, and the PR is a better artefact than a push anyway —
  # it is where the diff is read afterwards.
  local repo="ludorl82/labodeludo.dev" num
  num=$(gh pr list --repo "$repo" --base main --head dev --state open \
          --json number --jq '.[0].number' 2>/dev/null || true)
  if [ -z "$num" ]; then
    gh pr create --repo "$repo" --base main --head dev \
      --title "Ce que gpu-01 sait : publication du matin" \
      --body "Automatisé (daily-gpu-01-sync). Uniquement des fichiers de données : la dépêche, les questions suggérées, la topologie. Les gardes sont passées avant le commit." \
      >/dev/null 2>&1 \
      || { summary+=("main: FAILED to open the pull request"); fail=1; return 0; }
    num=$(gh pr list --repo "$repo" --base main --head dev --state open \
            --json number --jq '.[0].number' 2>/dev/null || true)
  fi
  [ -n "$num" ] || { summary+=("main: no pull request to merge"); fail=1; return 0; }

  if gh pr merge "$num" --repo "$repo" --merge --delete-branch=false >/dev/null 2>&1; then
    summary+=("main: published (PR #$num)")
  else
    summary+=("main: FAILED to merge PR #$num")
    fail=1
  fi
}

# --------------------------------------------------------------------------
# The run
# --------------------------------------------------------------------------
scratch=$(mktemp -d /tmp/daily-gpu-01-sync.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/snapshots"
for r in "${PUBLIC_REPOS[@]}"; do
  git clone -q --depth 1 "https://github.com/ludorl82/$r.git" "$scratch/snapshots/$r"
done
git clone -q --depth 1 --branch dev "git@github.com:ludorl82/labodeludo.dev.git" "$scratch/site"

# Yesterday's topology, read before the join overwrites it. The committed copy
# IS the previous state, so nothing has to be stored between runs.
git -C "$scratch/site" show HEAD:src/data/architecture.json \
  > "$scratch/architecture.prev.json" 2>/dev/null || true

python3 "$scratch/site/scripts/topology/join-topology.py" \
  "$scratch/snapshots" "$scratch/site/src/data/architecture.json"

run_dispatch "$scratch"
run_openers "$scratch"

# Only these three files may have moved. Anything else means a session went
# somewhere it should not have, and the commit is refused rather than
# inspected afterwards.
changed=$(git -C "$scratch/site" status --porcelain | awk '{print $2}' \
  | grep -v -e '__pycache__' || true)
stray=$(grep -v -e '^src/data/architecture.json$' \
               -e '^src/data/dispatch.json$' \
               -e '^src/data/openers.json$' <<<"$changed" || true)
if [ -n "${stray// /}" ]; then
  log "a session touched unexpected files: $stray — NOT committing"
  summary+=("REFUSED: unexpected files ($(tr '\n' ' ' <<<"$stray"))")
  fail=1
else
  grep -qx 'src/data/architecture.json' <<<"$changed" && arch_moved=1
  [ "$arch_moved" = 1 ] && git -C "$scratch/site" add src/data/architecture.json
  [ "$dispatch_published" = 1 ] && git -C "$scratch/site" add src/data/dispatch.json
  [ "$openers_published" = 1 ] && git -C "$scratch/site" add src/data/openers.json

  if git -C "$scratch/site" diff --cached --quiet; then
    summary+=("nothing to commit")
  else
    git -C "$scratch/site" -c user.name=ludorl82 -c user.email=alerts@example.com \
      commit -q -m "Ce que gpu-01 sait : rafraîchissement du matin

Automatisé (daily-gpu-01-sync). Données publiques seulement.

La dépêche est une phrase sur ce qui a bougé dans le parc depuis hier.
Le diff est calculé, pas raconté : une garde refuse toute machine qui
n'y figure pas. Les questions suggérées sont de vraies questions posées
par des visiteurs, publiées mot pour mot ou pas du tout.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
    # A shallow clone can still rebase onto its own remote branch; if the
    # weekly job pushed while this ran, take its work and replay on top.
    if git -C "$scratch/site" pull -q --rebase origin dev \
       && git -C "$scratch/site" push -q origin HEAD:dev; then
      summary+=("pushed ($(git -C "$scratch/site" rev-parse --short HEAD))")
      publish_to_main "$scratch/site"
    else
      summary+=("FAILED to push")
      fail=1
    fi
  fi
fi

msg=$(printf '%s; ' "${summary[@]}")
log "$msg"

if [ "$fail" = 1 ]; then
  kuma down "$msg"
  notify "gpu-01 sync: échec" "$msg"
  exit 1
fi

kuma up "$msg"
# Quiet mornings are the common case and do not deserve a phone buzz.
if [ "$dispatch_published" = 1 ] || [ "$openers_published" = 1 ]; then
  notify "gpu-01 sync" "$msg"
fi
exit 0
