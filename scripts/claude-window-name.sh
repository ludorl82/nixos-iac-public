# Prints a memorable, unique name for a Claude window: expression-nn.
#
# Numbered names (claude-2, claude-3) say nothing about which window is which,
# and the same string is used for the Remote Control session — so the phone
# shows a list of near-identical entries. A phrase is instantly recognisable in
# the app and in the tmux status bar.
#
# The vocabulary is gpu-01's: wry Québécois, Elvis Gratton as loose inspiration.
# Same register as the rotating quips on the 404 and author pages — a light
# surface, not an article. The sacres here are the soft ones (mosus, bateche,
# caline, tabarnouche); no real ones, and no franglais, which is the thing that
# actually failed when gpu-01's voice was first tried.
#
# ASCII only, and that is deliberate: these strings become a tmux window name
# AND a Remote Control session name. Lowercase throughout, accents dropped
# rather than risked (a-peu-pres, caline), and no spaces.
#
# Usage: claude-window-name [taken-name ...]
# Names already in use are passed as arguments and never returned.
#
# Kept as a .sh file rather than inline in a Nix `''` string on purpose: bash
# array syntax is ${ARR[i]}, which Nix would try to interpolate. readFile keeps
# the two languages from fighting over the same sigil.

PHRASE=(
  # ça fait la job
  ca-clique ca-marche ca-roule ca-pogne ca-tient ca-vire-ben
  pas-pire en-masse tiguidou sur-la-coche correct-de-meme ben-raide

  # ça fait pas la job
  ca-plante ca-lache dans-le-champ parti-en-peur dans-le-jus
  pantoute magane mal-a-main vire-en-rond a-peu-pres

  # ce qu'on fait avec
  gosser pitonner zigonner garrocher pogner toffer
  ploguer debarquer embarquer bricoler

  # ce que c'est
  patente bibitte bebelle gossage broue-dans-le-toupet

  # les sacres doux
  mosus bateche caline tabarnouche seigneur
)

is_taken() {
  local candidate="$1"; shift
  local t
  for t in "$@"; do
    [ "$t" = "$candidate" ] && return 0
  done
  return 1
}

for _ in $(seq 1 60); do
  p="${PHRASE[$((RANDOM % ${#PHRASE[@]}))]}"
  n="$((RANDOM % 90 + 10))"
  cand="$p-$n"
  if ! is_taken "$cand" "$@"; then
    echo "$cand"
    exit 0
  fi
done

# ~40 phrases x 90 numbers, so exhausting 60 tries means something is very
# wrong (or there are thousands of windows). Fall back to something guaranteed
# unique rather than returning a name that collides.
echo "claude-$$-$RANDOM"
