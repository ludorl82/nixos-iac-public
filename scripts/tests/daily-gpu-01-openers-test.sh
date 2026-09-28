#!/usr/bin/env bash
# Tests for daily-gpu-01-sync.sh's suggested-questions path.
#
# The existing suite covers publish_to_main and nothing else — which is how a
# whole branch of this job could ship with 18/18 green and not one assertion
# touching it. This covers the other half: what run_openers decides when its
# two sources succeed, fail, or have nothing to do.
#
# The gates themselves are tested in labodeludo.dev (check-generated,
# merge-openers, check-answerable and check-openers each have an offline suite).
# What is proven HERE is the wiring, because the wiring holds the decisions no
# single gate can see:
#
#   * the written half runs even when the real half found nothing — that is
#     precisely the morning it exists for;
#   * a panel already full costs no model call at all;
#   * a refusal in the written half must not take the real questions down;
#   * the probe token reaches the gate that asks production, or the job feeds
#     the popularity list it is meant to police.
#
# Everything that leaves the machine is stubbed: curl, the model driver, and
# the gate that asks production. The real Python gates run for real, against a
# real copy of the site's content, so a question this suite publishes is one
# the shipped gates accepted.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB="$SCRIPTS/daily-gpu-01-sync.sh"
SITE_SRC="${LABODELUDO_DIR:-$HOME/git/ludorl82/labodeludo.dev}"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bobopeners-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', wanted '$3'"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: '$2' lacks '$3'";; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$2' still has '$3'";; *) ok "$1";; esac; }

[ -d "$SITE_SRC/scripts/topology" ] || {
  echo "need labodeludo.dev at $SITE_SRC (set LABODELUDO_DIR)"; exit 1; }

# Lift the three functions out of the driver; sourcing the driver would run it.
for fn in run_openers_real run_openers_curated run_openers_written run_openers openers_new; do
  sed -n "/^$fn() {/,/^}/p" "$JOB" >> "$ROOT/fn.sh"
done
# Assert on EACH name, not on one of them. The suite passed for a while with
# run_openers_curated missing entirely — bash reported "command not found",
# the curated half silently produced nothing, and 33 assertions stayed green
# on a path that does not exist in production.
for fn in run_openers_real run_openers_curated run_openers_written run_openers openers_new; do
  grep -q "^$fn() {" "$ROOT/fn.sh" || { echo "extraction failed: $fn"; exit 1; }
done
# shellcheck source=/dev/null
. "$ROOT/fn.sh"

STUB_DIR="$ROOT/stub"; export STUB_DIR
SCRIPT_DIR="$ROOT/bin"
POPULAR_TOKEN="$ROOT/token"
# A driver global the lifted functions need. Every one of these that the
# suite forgets becomes an "unbound variable" abort inside a half, and the
# failure reads as a logic bug fifteen assertions later.
ANSWERABLE_CACHE="$ROOT/answerable-cache.json"
OPENERS_DAY_FILE="$ROOT/openers-day"
echo "s3kr3t" > "$POPULAR_TOKEN"
mkdir -p "$ROOT/bin"

# curl: serves the two URLs the job fetches, from files the test stages.
cat > "$ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */api/gpu-01/popular)
      [ "${CURL_POPULAR_RC:-0}" = 0 ] || exit 1
      cat "$STUB_DIR/popular.json"; exit 0 ;;
    */gpu-01-grounding.json)
      [ "${CURL_GROUNDING_RC:-0}" = 0 ] || exit 1
      cat "$STUB_DIR/grounding.json"; exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$ROOT/bin/curl"

# The driver is invoked as `python3 ask-local.py`, so the stub is Python. It
# returns what the test staged and then runs the REAL gate on it, exactly as
# the driver does — so a staged answer the gate refuses fails here too, which
# is the whole point of staging a bad one.
cat > "$ROOT/bin/ask-local.py" <<'STUB'
#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys

d = os.environ["STUB_DIR"]
with open(f"{d}/calls", "a", encoding="utf-8") as fh:
    fh.write("ask-local\n")

argv, out, prompt, attach, check = sys.argv[1:], None, "", "", []
i = 0
while i < len(argv):
    if argv[i] == "--out":
        out, i = argv[i + 1], i + 2
    elif argv[i] == "--prompt":
        prompt, i = argv[i + 1], i + 2
    elif argv[i] == "--attach":
        attach, i = argv[i + 1], i + 2
    elif argv[i] == "--":
        check = argv[i + 1:]
        break
    else:
        i += 1

# The written half is called once per language, both times with the same
# prompt, so the attached corpus is what says which call this is.
if "openers-generate.md" in prompt:
    lang = "en" if "corpus-en.json" in attach else "fr"
    src = f"{d}/written-answer-{lang}.json"
    # The fresh pass uses the same prompt with its own corpus directory.
    if "gen-fresh" in attach:
        src = f"{d}/fresh-answer-{lang}.json"
else:
    src = f"{d}/real-answer.json"
if not os.path.exists(src):
    sys.exit(1)
shutil.copy(src, out)
cmd = [a.replace("$OUT", out) for a in check]
if subprocess.run(cmd, capture_output=True).returncode:
    # Faithful to ask-local.py: the refused attempt is deleted, never left for
    # a caller to publish by accident. ASK_LEAVES_DRAFT=1 makes it UNfaithful
    # on purpose, so the job's own defence can be tested rather than assumed.
    if os.environ.get("ASK_LEAVES_DRAFT") != "1":
        os.unlink(out)
    sys.exit(1)
sys.exit(0)
STUB
chmod +x "$ROOT/bin/ask-local.py"
export PATH="$ROOT/bin:$PATH"

# A site tree holding the REAL gates, with the one that talks to production
# replaced by a stub that records the token it was handed.
setup_site() {
  rm -rf "$ROOT/scratch"; mkdir -p "$ROOT/scratch/site/src/data"
  cp -r "$SITE_SRC/scripts" "$ROOT/scratch/site/scripts"
  cp -r "$SITE_SRC/src/content" "$ROOT/scratch/site/src/content"
  cat > "$ROOT/scratch/site/scripts/topology/check-answerable.py" <<'STUB'
#!/usr/bin/env python3
"""Stub: records the probe token it was given; keeps or drops per ANSWERABLE_MODE."""
import json
import os
import sys

path = sys.argv[1]
with open(os.environ["STUB_DIR"] + "/answerable-calls", "a", encoding="utf-8") as fh:
    fh.write(f"{path} token={os.environ.get('BOB_POPULAR_TOKEN', '')}\n")
doc = json.load(open(path, encoding="utf-8"))
if os.environ.get("ANSWERABLE_MODE") == "dropall":
    doc["openers"] = []
# Drop by substring, so a case can retire ONE dead end and still watch the
# other sources fill the panel — which is what production does.
needle = os.environ.get("ANSWERABLE_DROP", "")
if needle:
    doc["openers"] = [q for q in doc["openers"] if needle not in q]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False)
print(f"{len(doc['openers'])} kept (0 unverified), 0 dropped as dead ends")
STUB
  echo '{"generated":"x","openers":[]}' > "$ROOT/scratch/site/src/data/openers.json"
  # The curated list, EMPTY by default. An empty third source is a real state
  # — a site that has not written one — and it keeps every case that predates
  # this source behaving exactly as it did. The curated cases stage their own.
  echo '{"fr": [], "en": []}' > "$ROOT/scratch/site/src/data/openers-curated.json"
  git -C "$ROOT/scratch/site" init -q
  git -C "$ROOT/scratch/site" -c user.email=t@t -c user.name=t add -A
  git -C "$ROOT/scratch/site" -c user.email=t@t -c user.name=t commit -qm base
}

stage() {
  rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"
  # a fresh day for every scenario: the once-a-day stamp is real state, and it
  # leaked from one scenario into the next the first time it existed
  rm -f "$OPENERS_DAY_FILE"
  python3 - "$STUB_DIR/grounding.json" <<'PY'
import json, sys
json.dump({
    "generated": "2026-09-15T04:30:00Z",
    "corpusFields": "kind|slug|date|title|en",
    # August on purpose: nothing inside the fresh window (7 days before
    # 2026-09-15), so every scenario that predates the fresh pass runs exactly
    # as it did. The fresh scenarios add their own recent article.
    "corpus": "\n".join(f"article|article-numero-{i}|2026-08-{i:02d}|Article numéro {i}|en"
                        for i in range(1, 12)),
    "fleet": "gpu-02 | gpu-node | vlan10\nap-01 | access-point | vlan50",
}, open(sys.argv[1], "w"), ensure_ascii=False)
PY
  echo '{"candidates": []}' > "$STUB_DIR/popular.json"
  setup_site
}

# candidates <question>... — a popular list, and a real half that picks it all
candidates() {
  python3 - "$STUB_DIR" "$@" <<'PY'
import json, sys
d, qs = sys.argv[1], sys.argv[2:]
json.dump({"candidates": [{"n": 9 - i, "text": q} for i, q in enumerate(qs)]},
          open(f"{d}/popular.json", "w"), ensure_ascii=False)
json.dump({"openers": qs}, open(f"{d}/real-answer.json", "w"), ensure_ascii=False)
PY
}

# writes <lang> <question>... — what the model answers for that language's call
writes() {
  python3 - "$STUB_DIR" "$@" <<'PY'
import json, sys
d, lang, qs = sys.argv[1], sys.argv[2], sys.argv[3:]
json.dump({"openers": qs}, open(f"{d}/written-answer-{lang}.json", "w"), ensure_ascii=False)
PY
}

go() {
  summary=(); fail=0; openers_published=0
  # The driver's stdout carries the corpus line, which is the only place the
  # gap handed to the written half is visible. Asserting on counts alone let a
  # mutation that ignored the curated source pass unnoticed.
  run_openers "$ROOT/scratch" > "$ROOT/driver.log" 2>&1
  SUMMARY="$(printf '%s; ' "${summary[@]}")"
  PANEL="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['openers'])" \
           "$ROOT/scratch/site/src/data/openers.json")"
  WRITTEN="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['written']))" \
             "$ROOT/scratch/site/src/data/openers.json")"
  CURATED="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('curated',[])))" \
             "$ROOT/scratch/site/src/data/openers.json")"
  LOG="$(cat "$ROOT/driver.log" 2>/dev/null)"
  # Order, not just membership: precedence is the decision, and two sources
  # whose questions all fit produce the same SET whichever order they are
  # merged in. Only the first entry shows which one won.
  # The PROVENANCE of the first button, not its text: the rotation decides
  # which curated question leads, and pinning the text makes the assertion a
  # hostage to the calendar.
  FIRST_KIND="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1])); o=d['openers']
if not o: print('none')
elif o[0] in d.get('curated',[]): print('curated')
elif o[0] in d.get('written',[]): print('written')
else: print('asked')" "$ROOT/scratch/site/src/data/openers.json")"
  CALLS="$(wc -l < "$STUB_DIR/calls" 2>/dev/null || echo 0)"
}

# Eight questions on eight subjects, each grounded in the real article bodies
# and each accepted by the real gates. Distinct subjects because check-openers
# and check-generated both refuse two questions sharing two content words, so
# near-identical filler can never stand in for a full panel.
FR=(
  "Comment Frigate écrit ses images sur le stockage ?"
  "Pourquoi le cluster k3s draine ses nœuds la nuit ?"
  "Ça fait quoi, gpu-02, dans ton rack à toi ?"
  "Comment Ollama garde son modèle en mémoire ?"
)
EN=(
  "How does Ollama share the two graphics cards?"
  "Why did your NixOS rebuild break the network?"
  "What does Uptime Kuma watch on your cluster?"
  "How do you publish a static site with S3?"
)
FR1="${FR[0]}"
FR2="${FR[1]}"

# --------------------------------------------------------------------------
say "the written half runs when the real half found nothing"
stage
writes fr "${FR[@]}"
writes en "${EN[@]}"
go
has "said no real question was eligible" "$SUMMARY" "no eligible question asked lately"
# One call per language: asked for both at once the model wrote four good
# French questions and no English one in three runs out of four.
is  "the model was called twice, once per language" "$CALLS" "2"
is  "it published" "$openers_published" "1"
is  "and did not fail" "$fail" "0"
has "the written questions are on the panel" "$PANEL" "Frigate"
is  "all eight are recorded as written" "$WRITTEN" "8"
is  "and none as curated, the list being empty" "$CURATED" "0"

# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
say "the curated source sits between the asked and the written"
stage
# Ludo's own list, staged for this case only. Two per language so the written
# half still has room — the interplay is the point, not a curated takeover.
cat > "$ROOT/scratch/site/src/data/openers-curated.json" <<'CUR'
{"fr": ["Pourquoi tu as débranché le NAS exprès ?",
        "Comment tu publies ton infrastructure sans donner tes secrets ?"],
 "en": ["Why did you unplug the NAS on purpose?",
        "What broke on a Thursday night with MongoDB?"]}
CUR
writes fr "${FR[@]:0:2}"
writes en "${EN[@]:0:2}"
go
is  "it published"                        "$openers_published" "1"
is  "and did not fail"                    "$fail" "0"
has "a curated question is on the panel"  "$PANEL" "débranché le NAS exprès"
is  "two per language recorded as curated" "$CURATED" "4"
has "the written half still filled the rest" "$PANEL" "Frigate"
# The gap handed to the written half must account for what curated already
# claims. Measured against the asked half alone, gpu-01 would write questions for
# buttons that are taken and the merge would drop them — model calls spent on
# output that cannot ship.
# The gap is visible in the corpus line the driver prints; the suite keeps
# the summary, so assert on the count that proves it instead: eight buttons
# with four curated leaves four for the written half.
is  "four buttons left to the written half" "$WRITTEN" "4"
has "the gap handed over counted them"     "$LOG" "need 2 fr + 2 en"
is  "and a curated question leads the panel" "$FIRST_KIND" "curated"
# Every source that produced something asks production, and every ask carries
# the probe token — or the gate feeds the popularity list it exists to police.
# Two here, not three: the real half found nothing eligible, so it never asked.
is  "each producing source asked production" "$(grep -c 'token=s3kr3t' "$STUB_DIR/answerable-calls" 2>/dev/null || echo 0)" "2"
# And the driver must survive the cache being unset — "ask every time", never
# an abort. Under `set -u` a bare reference kills the half it is in, and the
# failure surfaces fifteen assertions later as a logic bug.
( unset ANSWERABLE_CACHE
  stage; writes fr "${FR[@]:0:2}"; writes en "${EN[@]:0:2}"; go
  grep -q 'unbound variable' "$ROOT/driver.log" && exit 1
  [ "$openers_published" = 1 ] || exit 1 ) \
  && ok "no cache configured is a slower run, not a broken one" \
  || bad "an unset cache aborted a half"

# --------------------------------------------------------------------------
say "a curated question gpu-01 will not answer is dropped like any other"
stage
cat > "$ROOT/scratch/site/src/data/openers-curated.json" <<'CUR'
{"fr": ["Pourquoi tu as débranché le NAS exprès ?"], "en": []}
CUR
# EXPORT, not a shell variable: the gate is a separate process and reads the
# environment. Set without exporting, this case silently tested nothing.
export ANSWERABLE_DROP="débranché le NAS"
writes fr "${FR[@]:0:4}"
writes en "${EN[@]:0:4}"
go
unset ANSWERABLE_DROP
hasnt "the dead end is off the panel" "$PANEL" "débranché le NAS exprès"
is    "and it still published"        "$openers_published" "1"
is    "and did not fail"              "$fail" "0"

# --------------------------------------------------------------------------
say "a panel already full costs no model call"
stage
candidates "${FR[@]}" "${EN[@]}"
writes fr "$FR1"
writes en "${EN[0]}"
go
is  "the model was called once, for the real half only" "$CALLS" "1"
has "said the panel was already full" "$SUMMARY" "panel full from real questions"
is  "it published" "$openers_published" "1"
is  "nothing is recorded as written" "$WRITTEN" "0"

# --------------------------------------------------------------------------
say "the real half cannot choose: not a failure, the other sources fill the panel"
stage
candidates "${FR[@]}" "${EN[@]}"
# an answer the gate refuses: a question nobody asked, which the verbatim rule
# catches whatever else is true of it
python3 -c 'import json,sys; json.dump({"openers":["Est-ce que tu roules Nutanix sur tes serveurs ?"]}, open(sys.argv[1],"w"), ensure_ascii=False)' \
  "$STUB_DIR/real-answer.json"
writes fr "$FR1"
writes en "${EN[0]}"
go
has "said it could not choose"          "$SUMMARY" "could not choose among the asked questions"
is  "and it is NOT a failure"           "$fail" "0"
is  "the panel is published anyway"     "$openers_published" "1"
hasnt "the refused pick is not on it"   "$PANEL" "Nutanix"
[ "$PANEL" = "[]" ] && bad "the other sources filled the panel" || ok "the other sources filled the panel"

# --------------------------------------------------------------------------
say "the written half being refused does not sink the real questions"
# The refused fixtures name a product NO published article mentions, because
# the gate refuses a written question on vocabulary. They said "Proxmox" until
# 2026-09-17, when an article quoted the very question the gate once let
# through — the word entered the corpus and three scenarios went red with the
# driver unchanged. If these fail again, check the word is still absent:
#   grep -rli Nutanix labodeludo.dev/src/content
stage
candidates "$FR2"
# an invented product: check-generated refuses it, so the driver reports failure
writes fr "Est-ce que tu roules Nutanix sur tes serveurs ?"
writes en "Do you run Nutanix on your servers?"
go
has "said nothing written survived" "$SUMMARY" "nothing written survived"
is  "it still published" "$openers_published" "1"
is  "and did not fail the job" "$fail" "0"
has "the real question is on the panel" "$PANEL" "draine"
hasnt "the refused one is not" "$PANEL" "Nutanix"

# --------------------------------------------------------------------------
say "a driver that leaves its refused draft behind still publishes nothing"
# The merge reads whatever is on disk, and the only thing that stopped a
# REFUSED question from reaching the panel was the driver deleting its own
# file. That coupling is invisible and one edit away from breaking, so the job
# clears the file itself — and this is the case that proves it, with a driver
# deliberately made unfaithful.
stage
candidates "$FR2"
writes fr "Est-ce que tu roules Nutanix sur tes serveurs ?"
writes en "Do you run Nutanix on your servers?"
ASK_LEAVES_DRAFT=1 go
has "said nothing written survived" "$SUMMARY" "nothing written survived"
hasnt "the refused question is not on the panel" "$PANEL" "Nutanix"
is  "the real question still published" "$openers_published" "1"
has "and it is the real one" "$PANEL" "draine"

# --------------------------------------------------------------------------
say "one language refused, the other kept: the refused draft stays off the panel"
# The sharp case for the per-language cleanup. When BOTH languages fail the
# morning short-circuits and no draft can reach the merge; when only ONE fails,
# the merge runs and reads both files. So a refused draft left on disk would be
# joined to the good language and published.
stage
writes fr "Est-ce que tu roules Nutanix sur tes serveurs ?"
writes en "${EN[0]}"
ASK_LEAVES_DRAFT=1 go
has "said the French half was refused" "$SUMMARY" "nothing written survived in fr"
hasnt "the refused French question is not on the panel" "$PANEL" "Nutanix"
has "the English one is" "$PANEL" "Ollama"
is  "it published" "$openers_published" "1"

# --------------------------------------------------------------------------
say "the probe token reaches the gate that asks production"
# Both halves verify against production, and production counts what it is
# asked; without this marker the job feeds the list it is meant to police. The
# case has to be one where BOTH halves get that far — asserting it after a case
# where the written half failed early proved only that the real half ran.
stage
candidates "$FR2"
# The real half keeps one French question, so the written half is asked for
# three French and four English.
writes fr "${FR[0]}" "${FR[2]}" "${FR[3]}"
writes en "${EN[@]}"
go
is "both halves reached it" \
   "$(grep -c 'token=s3kr3t' "$STUB_DIR/answerable-calls" 2>/dev/null || echo 0)" "2"
is "and every ask carried the token" \
   "$(grep -c 'token=' "$STUB_DIR/answerable-calls" 2>/dev/null || echo 0)" "2"

# --------------------------------------------------------------------------
say "nothing survives anywhere: the panel is left to its fallbacks"
stage
candidates "$FR2"
writes fr "$FR1"
writes en "${EN[0]}"
ANSWERABLE_MODE=dropall go
has "said so" "$SUMMARY" "left to the fallbacks"
is  "nothing was published" "$openers_published" "0"
is  "the data file is untouched" \
    "$(git -C "$ROOT/scratch/site" status --porcelain src/data/openers.json | wc -l)" "0"
is  "and it is still not a failure" "$fail" "0"

# --------------------------------------------------------------------------
say "the grounding cannot be read: the real questions publish anyway"
stage
candidates "$FR2"
writes fr "$FR1"
writes en "${EN[0]}"
CURL_GROUNDING_RC=1 go
has "said the grounding was unreadable" "$SUMMARY" "could not read the grounding"
is  "it still published the real question" "$openers_published" "1"
is  "and did not fail" "$fail" "0"
hasnt "and wrote nothing" "$PANEL" "Frigate"

# --------------------------------------------------------------------------
say "the second run of the morning leaves the panel alone"
stage
candidates "${FR[@]}" "${EN[@]}"
writes fr "$FR1"
writes en "${EN[0]}"
rm -f "$OPENERS_DAY_FILE"
go
is  "the first run publishes"        "$openers_published" "1"
is  "and stamps the day"             "$(cat "$OPENERS_DAY_FILE")" "$(date +%F)"
FIRST_PANEL="$PANEL"; FIRST_CALLS="$CALLS"
go
has "the second says why it stopped" "$SUMMARY" "panel already refreshed today"
is  "it publishes nothing"           "$openers_published" "0"
is  "and it is not a failure"        "$fail" "0"
is  "the panel is untouched"         "$PANEL" "$FIRST_PANEL"
is  "no model call at all"           "$CALLS" "$FIRST_CALLS"
# yesterday's stamp must not stop tomorrow
echo "2026-01-01" > "$OPENERS_DAY_FILE"
go
is  "a stale stamp lets it run"      "$openers_published" "1"

# --------------------------------------------------------------------------
say "a reshuffled panel is not news; a question that was not there is"
# 2026-09-17: every morning F republishes openers.json, so "published" was
# always true and every quiet night buzzed the phone. The rule is now the
# count of questions tonight that were not on the previous panel.
mk() { python3 -c 'import json,sys; json.dump({"curated":[],"generated":sys.argv[1],"openers":sys.argv[2:],"written":[]}, open(sys.argv[1]+".json","w"))' "$@"; }
( cd "$ROOT" && mk prev "D'où vient le nom de gpu-01 ?" "which model powers you?" "c'est quoi ton setup ?" \
             && mk same "which model powers you?" "c'est quoi ton setup ?" "D'où vient le nom de gpu-01 ?" \
             && mk fewer "which model powers you?" \
             && mk plus "which model powers you?" "Comment tu as fait pour que Frigate utilise le GPU?" )
is "same questions, new order and stamp: nothing new" "$(openers_new "$ROOT/prev.json" "$ROOT/same.json")" "0"
is "a question dropped: nothing new"                  "$(openers_new "$ROOT/prev.json" "$ROOT/fewer.json")" "0"
is "a question added: one new"                        "$(openers_new "$ROOT/prev.json" "$ROOT/plus.json")" "1"
is "no previous panel: every question is new"         "$(openers_new "$ROOT/absent.json" "$ROOT/prev.json")" "3"
# and the end of the job buzzes on that count, not on the publish flag
tail_block=$(sed -n '/^kuma up "\$msg"/,/^exit 0/p' "$JOB")
has   "the notify rule reads the new-question count" "$tail_block" 'new_openers:-0}" -gt 0'
hasnt "and no longer the publish flag"               "$tail_block" '"$openers_published" = 1'

# --------------------------------------------------------------------------
# The fresh pass — a question of gpu-01's about this week's article
# --------------------------------------------------------------------------
# recent_article — one article inside the fresh window, with an English version
recent_article() {
  python3 - "$STUB_DIR/grounding.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["corpus"] += "\narticle|la-reponse-par-la-mauvaise-patte|2026-09-14|La réponse par la mauvaise patte|en"
json.dump(g, open(sys.argv[1], "w"), ensure_ascii=False)
PY
}
# fresh <lang> <question> — what the model answers for the fresh call
fresh() {
  python3 - "$STUB_DIR" "$@" <<'PY'
import json, sys
d, lang, qs = sys.argv[1], sys.argv[2], sys.argv[3:]
json.dump({"openers": qs}, open(f"{d}/fresh-answer-{lang}.json", "w"), ensure_ascii=False)
PY
}
FRESH_FR="Pourquoi tes sessions SSH gelaient-elles après une minute ?"
FRESH_EN="Why did your SSH sessions freeze after a minute?"
curated_full() {
  python3 - "$ROOT/scratch/site/src/data/openers-curated.json" "${FR[@]}" "${EN[@]}" <<'PY'
import json, sys
qs = sys.argv[2:]
json.dump({"fr": qs[:4], "en": qs[4:]}, open(sys.argv[1], "w"), ensure_ascii=False)
PY
}

say "no recent article: the fresh pass costs no model call"
stage
writes fr "${FR[@]}"
writes en "${EN[@]}"
go
has "said there was nothing new"          "$SUMMARY" "F fresh: no article in the last"
is  "still only the two gap calls"        "$CALLS" "2"

say "a new article gets a button of its own, AHEAD of the curated list"
stage
recent_article
curated_full
fresh fr "$FRESH_FR"
fresh en "$FRESH_EN"
go
is  "it published"                        "$openers_published" "1"
is  "and did not fail"                    "$fail" "0"
has "the French fresh question is on the panel"  "$PANEL" "$FRESH_FR"
has "the English one too"                 "$PANEL" "$FRESH_EN"
is  "both are recorded as written, they are gpu-01's" "$WRITTEN" "2"
is  "the curated list gives up one button per language" "$CURATED" "6"
is  "fresh leads, curated follows"        "$FIRST_KIND" "written"
is  "two calls, both fresh: the gap was full" "$CALLS" "2"

say "a fresh question the gate refuses stays off the panel, the rest publishes"
stage
recent_article
curated_full
fresh fr "Pourquoi mes sessions SSH gelaient-elles après une minute ?"
fresh en "$FRESH_EN"
go
hasnt "the owner's-voice question is not published" "$PANEL" "mes sessions"
has   "the English one is"                "$PANEL" "$FRESH_EN"
has   "the refusal is reported"           "$SUMMARY" "F fresh: nothing written survived in fr"
is    "and it is not a failure of the job" "$fail" "0"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
