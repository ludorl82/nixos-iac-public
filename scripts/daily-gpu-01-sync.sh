#!/usr/bin/env bash
# Daily — what gpu-01 knows, refreshed every morning.
#
# Two deliverables, both small, both public-only:
#
#   Session E — the dispatch: one line about what moved in the fleet since
#     yesterday, so "quoi de neuf ?" has an answer that is actually new.
#   Session F — the suggested questions: real ones people asked, chosen from a
#     counted list and published verbatim or not at all, plus — since
#     2026-09-15 — written ones to fill whatever buttons those leave empty,
#     grounded word by word in the published articles and checked against gpu-01
#     himself before they ship.
#
# Both go through scripts/ask-local.py — one call, the gate, two corrections —
# on the lab's own model from 2026-09-09 to 2026-09-13, on qwen3.8-flash
# (Alibaba Cloud Model Studio) until 2026-09-26, and on the lab's own model
# again since — qwen38-27b, see the E note below. Both tasks are
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
# E is BACK on the lab's own model since 2026-09-26 (qwen38-27b, the dense
# Qwen3.8-27B that now serves every caller of gpu-01). It ran on qwen3.8-flash at
# Alibaba from 2026-09-13, when the local model was the 35B-A3B. Rehearsed on
# the 27B before the switch: 12 runs over three real diffs from the site's
# architecture.json history (2 to 12 days apart), 12 passes of check-dispatch
# on the FIRST attempt, 7 to 9 s each. Nothing in this job calls a hosted
# model any more, so the default below is ollama and the Alibaba key is not
# even fetched; ASK_BACKEND=openai in the environment brings both back.
#
# F is PINNED local since 2026-09-15 — its two calls set ASK_BACKEND=ollama, so the
# local model does the picking whatever this default says. F is the only
# session that sees visitor data: the counted list of questions asked of the
# chat, verbatim. The site promises those stay in the lab, and a privacy
# promise is not tradeable for convenience.
#
# What that trade was: F moved to the hosted model because the local 35B had
# chosen, as a suggested question, the false-premise example its own prompt
# names as a counter-example — the one judgement the gates cannot make. That
# risk comes back with it, and it is NOT mechanically caught on this side:
# check-openers.py can prove a stranger really asked a question, never that
# its premise is true. What the move buys is that nothing a visitor writes
# leaves the house.
#
# Key from KeePass, in the environment of the python process only.
ASK_BACKEND="${ASK_BACKEND:-ollama}"
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
  [ -n "$NTFY_TOKEN" ] || { log "no ntfy token — skipping notify: $1"; return 0; }
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
# Since 2026-09-15 this runs in two halves. The first selects real questions,
# exactly as before. The second WRITES questions to fill whatever the first
# left empty, because the alternative was never "only real questions" — it was
# four sentences hand-written in July, already invented and frozen since. Two
# sources, two gates, and openers.json says which is which.
run_openers_real() {
  local scratch="$1"
  local site="$scratch/site"
  local work="$scratch/openers"

  [ -s "$POPULAR_TOKEN" ] || { summary+=("F: skipped (no popular-questions token)"); return 0; }
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
    # Not a failure and no longer the end: a quiet fortnight is exactly when
    # the generated half earns its place.
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
  ASK_BACKEND=ollama python3 "$SCRIPT_DIR/ask-local.py" \
      --prompt "$site/scripts/topology/prompts/openers.md" \
      --out "$work/openers.json" \
      --attach candidates.json="$work/eligible.json" \
      -- python3 "$site/scripts/topology/check-openers.py" '$OUT' "$work/candidates.json" \
    || { # NOT A RED NIGHT (2026-09-17).
         #
         # This half SELECTS among questions visitors asked; the curated and
         # written halves follow it and fill whatever it leaves. Failing to
         # select is a night with no visitor question on the panel, not a
         # broken job — and the panel that morning was full, eight questions,
         # while the phone got "gpu-01 sync: échec" twice for it. The local model
         # had spent its five attempts picking a question its own prompt names
         # as a counter-example, then returning five French ones where four is
         # the maximum.
         #
         # A panel that ends up empty is still reported, downstream, where it
         # is actually known ("no question survived").
         summary+=("F: the model could not choose among the asked questions")
         return 0; }

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
                   "$work/openers.json" --filter --min 1 \
                   ${ANSWERABLE_CACHE:+--cache "$ANSWERABLE_CACHE"} --grounding "$work/grounding.json" 2>&1 | tail -1); then
    summary+=("F: $kept_note")
  else
    summary+=("F: nothing answerable survived ($kept_note)")
    return 0
  fi

  cp "$work/openers.json" "$work/kept.json"
}

# --------------------------------------------------------------------------
# The curated half — Ludo's own questions
# --------------------------------------------------------------------------
#
# The third source, added 2026-09-16 because the panel had no way to express
# "this one is worth asking". It must not be granted by feeding invented text
# into the verbatim half: the Worker names that laundering, and it would empty
# the only rule that makes "a visitor asked this" mean anything.
#
# NO MODEL RUNS HERE. The list is curated by a person, so the only decisions
# left are which slice and whether gpu-01 can still answer — a rotation keyed to
# the date, then the same answerability gate the other two sources pass. Every
# question in the list was asked of production before being written down; this
# reposes tonight's slice, because an article can be unpublished and a
# relevance floor can be retuned.
run_openers_curated() {
  local scratch="$1"
  local site="$scratch/site"
  local work="$scratch/openers"
  local list="$site/src/data/openers-curated.json"
  [ -s "$list" ] || { summary+=("F curated: no list"); return 0; }

  # --already: pick only what the real half left room for. Without it this
  # source picked eight, asked production eight times at six seconds apart, and
  # the merge dropped them all because the panel was already full. Measured on
  # its first live run.
  python3 "$site/scripts/topology/openers-curated.py" "$list" "$work/curated.json" 4 \
      --already "$work/kept.json" \
    || { rm -f "$work/curated.json"; summary+=("F curated: could not pick"); return 0; }

  # Same leak gate as the other two. These are Ludo's words rather than a
  # model's, which is a reason to keep the gate, not to drop it: a hand-written
  # question is exactly where a real hostname would slip in.
  python3 "$site/scripts/topology/scan-public.py" "$work/curated.json" \
    || { rm -f "$work/curated.json"
         summary+=("F curated: REFUSED by scan-public"); fail=1; return 0; }

  # An empty slice asks production nothing. check-answerable would happily run
  # over zero questions, but every ask costs six seconds of spacing against a
  # per-IP limiter shared with the other two sources — and a probe that proves
  # nothing is the kind of cost that never gets noticed.
  local n
  n=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['openers']))" \
        "$work/curated.json" 2>/dev/null || echo 0)
  if [ "$n" = 0 ]; then
    rm -f "$work/curated.json"
    summary+=("F curated: nothing curated for tonight")
    return 0
  fi

  # --min 0: losing every curated question is a smaller panel, not a failure.
  local note=""
  note=$(python3 "$site/scripts/topology/check-answerable.py" \
           "$work/curated.json" --filter --min 0 \
           ${ANSWERABLE_CACHE:+--cache "$ANSWERABLE_CACHE"} --grounding "$work/grounding.json" 2>&1 | tail -1) || true
  summary+=("F curated: $note")
}

# --------------------------------------------------------------------------
# The written half
# --------------------------------------------------------------------------
#
# Only ever as much as the real questions left unfilled, and never instead of
# one: `openers-corpus.py` computes the gap per language and exits 3 when there
# is none, so a good morning costs no model call at all.
#
# The verbatim rule cannot apply here, so it is replaced rather than dropped.
# check-generated.py holds every word carrying subject matter to the vocabulary
# of the published articles — the same text gpu-01's own retrieval searches — so a
# question about something this site never wrote cannot be written. Then
# check-answerable.py asks him, exactly as it does for the real ones. The first
# gate proves the thing exists; the second proves he has something to say about
# it; neither can do the other's job.
# FRESH MODE (2026-09-26): `run_openers_written <scratch> fresh`. The gap
# alone never opened — asked and curated questions filled all eight buttons
# every night from 2026-09-20 on — so gpu-01 wrote nothing, and a new article
# reached the panel only if a visitor asked about it first. In fresh mode the
# corpus keeps only the articles of the last OPENERS_FRESH_DAYS days, asks for
# ONE question per language, and the result outranks the curated questions
# (merge-openers --fresh). Same model, same three gates. No recent article, no
# model call. Rehearsed on qwen38-27b against the production grounding: 10/10
# through check-generated, both languages answered by production.
OPENERS_FRESH_DAYS="${OPENERS_FRESH_DAYS:-7}"

run_openers_written() {
  local scratch="$1"
  local mode="${2:-gap}"
  local site="$scratch/site"
  local work="$scratch/openers"
  # Fresh and gap write to their own files, so neither can overwrite what the
  # other already produced this morning.
  local pre=written gen="$work/gen" label="F" corpus_opt=()
  if [ "$mode" = fresh ]; then
    pre=fresh gen="$work/gen-fresh" label="F fresh" corpus_opt=(--fresh-days "${OPENERS_FRESH_DAYS:-7}")
  fi

  [ -s "$work/kept.json" ] || echo '{"openers": []}' > "$work/kept.json"

  # No stale answer may survive a refusal. The driver deletes the file it could
  # not get past the gate, but relying on that put a question the gate had just
  # REFUSED onto the panel in a rehearsal: every early return below leaves the
  # file untouched, and the merge reads whatever is there. So the file is the
  # written half's output only when this function runs to the end.
  rm -f "$work/$pre.json"

  # gpu-01's grounding as PRODUCTION serves it, not as this checkout would build
  # it: a question generated from a richer corpus than the answerer holds is a
  # question he cannot answer, which is the dead end all of this exists to
  # remove.
  if [ ! -s "$work/grounding.json" ]; then
    summary+=("$label: could not read the grounding (no written questions)")
    return 0
  fi

  local corpus_rc=0
  # The gap is measured against everything already claimed — asked AND
  # curated. Measuring it against the asked half alone would have gpu-01 write
  # questions for buttons the curated source is about to take, and the merge
  # would then drop them: model calls spent on output that cannot ship.
  # merge-openers.py is reused rather than reimplemented, so "already claimed"
  # is computed by the same code that will do the final merge, including its
  # per-language cap.
  #
  # Fresh runs BEFORE the curated half and outranks it, so only the asked
  # questions are claimed ahead of it. The gap run comes last and counts the
  # fresh ones as claimed too.
  if [ "$mode" = fresh ]; then
    cp "$work/kept.json" "$work/filled.json"
  else
    python3 "$site/scripts/topology/merge-openers.py" \
        ${OPENERS_HAVE_FRESH:+--fresh "$work/fresh.json"} \
        "$work/kept.json" "$work/curated.json" "$work/filled.json" \
        "$(date -u +%FT%TZ)" >/dev/null 2>&1 || cp "$work/kept.json" "$work/filled.json"
  fi
  python3 "$site/scripts/topology/openers-corpus.py" "${corpus_opt[@]}" "$work/grounding.json" \
    "$work/filled.json" "$site/src/content" "$gen" || corpus_rc=$?
  if [ "$corpus_rc" = 3 ]; then
    if [ "$mode" = fresh ]; then
      summary+=("$label: no article in the last ${OPENERS_FRESH_DAYS:-7} days, nothing written")
    else
      summary+=("$label: panel full from real questions, nothing written")
    fi
    return 0
  fi
  [ "$corpus_rc" = 0 ] || { summary+=("$label: could not build the corpus"); fail=1; return 0; }

  # One language per call. Asked for both at once the model wrote four good
  # French questions and no English one in three runs out of four — it can
  # write well or satisfy two simultaneous quotas, not both. A second call
  # costs about three seconds.
  local lang got=0
  for lang in fr en; do
    python3 -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1]))['need'][sys.argv[2]] else 1)" \
      "$gen/corpus.json" "$lang" || continue
    if ASK_BACKEND=ollama python3 "$SCRIPT_DIR/ask-local.py" \
        --prompt "$site/scripts/topology/prompts/openers-generate.md" \
        --out "$work/$pre-$lang.json" \
        --attach corpus.json="$gen/corpus-$lang.json" \
        -- python3 "$site/scripts/topology/check-generated.py" '$OUT' \
           "$gen/corpus-$lang.json" "$gen/vocabulary.json"; then
      got=1
    else
      # A refusal here is the gate working, and it costs one language, not the
      # morning: the other language and every real question still publish.
      rm -f "$work/$pre-$lang.json"
      summary+=("$label: nothing written survived in $lang")
    fi
  done
  if [ "$got" = 0 ]; then
    rm -f "$work/$pre.json"
    summary+=("$label: nothing written survived check-generated")
    return 0
  fi

  python3 "$site/scripts/topology/merge-openers.py" \
    "$work/$pre-fr.json" "$work/$pre-en.json" "$work/$pre.json" \
    "$(date -u +%FT%TZ)" >/dev/null \
    || { rm -f "$work/$pre.json"; summary+=("$label: could not join the two languages"); return 0; }

  python3 "$site/scripts/topology/scan-public.py" "$work/$pre.json" \
    || { rm -f "$work/$pre.json"
         summary+=("$label: REFUSED by scan-public (written)"); fail=1; return 0; }

  # --min 0: losing every written question is a smaller panel, not a failure.
  local note=""
  note=$(python3 "$site/scripts/topology/check-answerable.py" \
           "$work/$pre.json" --filter --min 0 \
           ${ANSWERABLE_CACHE:+--cache "$ANSWERABLE_CACHE"} --grounding "$work/grounding.json" 2>&1 | tail -1) || true
  summary+=("$label written: $note")
}

# --------------------------------------------------------------------------
# Publishing the two halves as one panel
# --------------------------------------------------------------------------
# Remembered verdicts live OUTSIDE the scratch directory, which is wiped every
# run — a cache that dies with the job is not a cache. Same convention as the
# nightly sync's own state.
ANSWERABLE_CACHE="${ANSWERABLE_CACHE:-$HOME/.local/state/daily-gpu-01-sync/answerable.json}"
# The day the panel was last published. Two Cronicle chains end at the same
# link — the 04:30 drift chain and the 04:45 diagram chain both run
# Architecture Refresh, which runs this job — so this job runs TWICE every
# morning. That is deliberate for the architecture data, and was never a
# decision about the questions: the panel was rebuilt at 04:34 and again at
# 05:11, two commits, two pull requests to main, two notifications, and seven
# of the eight buttons different between them (2026-09-19).
OPENERS_DAY_FILE="${OPENERS_DAY_FILE:-$HOME/.local/state/daily-gpu-01-sync/openers-day}"

run_openers() {
  local scratch="$1"
  local site="$scratch/site"
  local work="$scratch/openers"
  # `:-` throughout: a cache that is unset must mean "ask every time", never
  # an abort. Under `set -u` a bare reference kills the whole half — which
  # is what the wiring suite hit, because it lifts the run_openers*
  # functions out of this file and never saw the global.
  mkdir -p "$work" ${ANSWERABLE_CACHE:+"$(dirname "$ANSWERABLE_CACHE")"}

  # ONCE A DAY. The architecture half of this job earns its second run; the
  # panel does not. Local date on purpose: "today" is the reader's day, and
  # both morning runs fall in it. An unset file means "every time", the same
  # `:-` rule as the verdict cache, so the wiring suite keeps its old shape.
  local today; today=$(date +%F)
  if [ -n "${OPENERS_DAY_FILE:-}" ] && [ "$(cat "${OPENERS_DAY_FILE}" 2>/dev/null || true)" = "$today" ]; then
    summary+=("F: panel already refreshed today")
    return 0
  fi
  echo '{"openers": []}' > "$work/kept.json"

  # The grounding, fetched ONCE for all three sources: it keys the verdict
  # cache, and it used to be read only by the written half. A digest of it is
  # what says "what gpu-01 knows has not changed since we last asked", so every
  # source needs the same copy or they would disagree about which night it is.
  curl -fsS --max-time 30 https://labodeludo.dev/gpu-01-grounding.json \
       > "$work/grounding.json" 2>/dev/null || rm -f "$work/grounding.json"

  # check-answerable.py asks production, and production counts every question
  # it is asked. This marks those asks as checks so they are NOT tallied —
  # without it the gate feeds the popularity list it exists to police, and a
  # written question would be counted as if a visitor had typed it, then
  # republished the next day as a real one.
  if [ -s "$POPULAR_TOKEN" ]; then
    export BOB_POPULAR_TOKEN="$(cat "$POPULAR_TOKEN")"
  fi

  run_openers_real "$scratch"
  # Before the curated half, which it outranks: see OPENERS_FRESH_DAYS.
  rm -f "$work/fresh.json"
  run_openers_written "$scratch" fresh
  local OPENERS_HAVE_FRESH=""
  [ -s "$work/fresh.json" ] && OPENERS_HAVE_FRESH=1
  run_openers_curated "$scratch"
  # An absent or emptied curated file must not become `--curated /nonexistent`:
  # merge-openers treats an unreadable source as empty, but passing a path that
  # was never written hides a real failure behind a normal-looking panel.
  local curated_arg=""
  [ -s "$work/curated.json" ] && curated_arg=1
  run_openers_written "$scratch"

  python3 "$site/scripts/topology/merge-openers.py" \
    ${OPENERS_HAVE_FRESH:+--fresh "$work/fresh.json"} \
    ${curated_arg:+--curated "$work/curated.json"} \
    "$work/kept.json" "$work/written.json" "$site/src/data/openers.json" \
    "$(date -u +%FT%TZ)" || { summary+=("F: could not merge the sources"); fail=1; return 0; }

  local total
  total=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['openers']))" \
          "$site/src/data/openers.json")
  if [ "$total" = 0 ]; then
    # An empty file is a valid state — the site falls back to its hand-written
    # questions, per language — but there is no reason to commit one.
    git -C "$site" checkout -q -- src/data/openers.json 2>/dev/null || true
    summary+=("F: no question survived, panel left to the fallbacks")
    return 0
  fi
  openers_published=1
  # Stamped only on a panel that exists: a night that published nothing must
  # not silence the next run.
  if [ -n "${OPENERS_DAY_FILE:-}" ]; then
    mkdir -p "$(dirname "$OPENERS_DAY_FILE")" && date +%F > "$OPENERS_DAY_FILE"
  fi
  summary+=("F: $total suggested question(s)")
}

# How many questions on tonight's panel were not on the one published before.
# A missing or unreadable previous panel counts as empty: everything is new.
#
#   openers_new <previous openers.json> <tonight's openers.json>  -> count
openers_new() {
  python3 - "$1" "$2" <<'PYNEW'
import json, sys
def questions(path):
    try:
        return set(json.load(open(path)).get("openers") or [])
    except Exception:
        return set()
print(len(questions(sys.argv[2]) - questions(sys.argv[1])))
PYNEW
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

  # WHAT MAY TRAVEL ALONE. All of it is machine-written data that already
  # passed its own gate before reaching dev — never code, never prose.
  #
  # `fleet.json` and `gpu-01-vectors.json` joined on 2026-09-18. The parc file was
  # left out when this function was written, and the cost showed up as a lie on
  # the public rack drawing: gaming-01's RTX 3050 8 GB came out of vfio on
  # 2026-09-17, the nightly job published the correction to dev that evening,
  # and production still drew all three cards as passthrough two days later —
  # because every night that touches the parc puts fleet.json on dev, which
  # made this function decline, every time, in silence.
  #
  # It is safe here for the same reason the nightly driver commits it: it
  # crosses from private to public through TWO gates (the positive allowlist
  # and the private denylist) before it is ever on dev. The search index is
  # derived from articles already published.
  stray=$(grep -v -e '^src/data/architecture\.json$' \
                 -e '^src/data/dispatch\.json$' \
                 -e '^src/data/openers\.json$' \
                 -e '^src/data/fleet\.json$' \
                 -e '^public/gpu-01-vectors\.json$' <<<"$files" || true)
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
# Yesterday's panel, for the same reason: what counts as news is a question
# that was not on it.
git -C "$scratch/site" show HEAD:src/data/openers.json \
  > "$scratch/openers.prev.json" 2>/dev/null || true

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
n'y figure pas.

Les questions suggérées viennent de deux sources, et le champ « written »
d'openers.json dit lesquelles sont lesquelles. Celles posées par des
visiteurs sont publiées mot pour mot ou pas du tout. Celles écrites par
gpu-01 ne complètent que les boutons vides : chaque mot doit exister dans
les articles publiés, et gpu-01 doit accepter de répondre à la question.

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

# How much of tonight's panel is new. See the notify rule at the end.
new_openers=0
if [ "$openers_published" = 1 ]; then
  new_openers=$(openers_new "$scratch/openers.prev.json" "$scratch/site/src/data/openers.json") || new_openers=0
  [ "$new_openers" -gt 0 ] 2>/dev/null && summary+=("F: $new_openers new on the panel")
fi

msg=$(printf '%s; ' "${summary[@]}")
log "$msg"

if [ "$fail" = 1 ]; then
  kuma down "$msg"
  notify "gpu-01 sync: échec" "$msg"
  exit 1
fi

kuma up "$msg"
# Quiet mornings are the common case and do not deserve a phone buzz — the
# same rule as the diagram sync: say something when something changed.
#
# That was the intent, and it never held: F rewrites openers.json whenever any
# question survives its gates, which is every morning, so openers_published
# was true every run and every quiet night buzzed ("E: quiet night" in a
# notification, 2026-09-17, seven times in one day). News is a dispatch, or a
# question on the panel that was not there yesterday — the only way a
# stranger's words or a gpu-01-written question reach the site. A reshuffle of
# the same questions is not.
if [ "$dispatch_published" = 1 ] || [ "${new_openers:-0}" -gt 0 ]; then
  notify "gpu-01 sync" "$msg"
fi
exit 0
