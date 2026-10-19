#!/usr/bin/env bash
# Tests de labo-ha : une maison en JSON (LABO_HA_FAKE), chaque appel de service
# noté à côté. Ce qui compte : ce qui est refusé ne part JAMAIS, même dans une
# commande à moitié permise ou visée par une pièce entière.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
L="$HERE/../labo-ha.py"
ROOT=$(mktemp -d /tmp/labo-ha-test.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
pass=0; failed=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

house() { cat > "$ROOT/house.json" <<'EOF'
{"areas": [{"area_id": "bureau", "name": "Bureau"}, {"area_id": "salon", "name": "Salon"},
           {"area_id": "sous_sol", "name": "Sous-sol"}],
 "devices": [{"id": "d-lampe", "area_id": "salon"}, {"id": "d-stella", "area_id": "sous_sol"}],
 "entities": [
  {"entity_id": "light.bureau", "area_id": "bureau", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "light.salon_lampe", "device_id": "d-lampe", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "light.prise_des_serveurs", "area_id": "sous_sol", "options": {"conversation": {"should_expose": false}}},
  {"entity_id": "light.sous_sol", "area_id": "sous_sol", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "switch.stella", "device_id": "d-stella", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "switch.purificateur", "area_id": "salon", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "media_player.salon", "area_id": "salon", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "script.meteo", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "script.redemarrer_tout", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "lock.porte", "area_id": "salon", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "button.observateur_autoriser", "options": {"conversation": {"should_expose": false}}},
  {"entity_id": "light.vieille", "area_id": "salon", "disabled_by": "user", "options": {"conversation": {"should_expose": true}}},
  {"entity_id": "sensor.temperature_salon", "area_id": "salon", "options": {"conversation": {"should_expose": true}}}
 ],
 "states": [
  {"entity_id": "light.bureau", "state": "on", "attributes": {"friendly_name": "Lumière du bureau", "brightness": 200}},
  {"entity_id": "light.salon_lampe", "state": "off", "attributes": {"friendly_name": "Lampe du salon"}},
  {"entity_id": "light.prise_des_serveurs", "state": "on", "attributes": {"friendly_name": "Prise des serveurs"}},
  {"entity_id": "light.sous_sol", "state": "on", "attributes": {"friendly_name": "Sous-sol"}},
  {"entity_id": "switch.stella", "state": "on", "attributes": {"friendly_name": "stella"}},
  {"entity_id": "switch.purificateur", "state": "off", "attributes": {"friendly_name": "Purificateur"}},
  {"entity_id": "media_player.salon", "state": "playing", "attributes": {"friendly_name": "Salon", "media_title": "Bob"}},
  {"entity_id": "lock.porte", "state": "locked", "attributes": {"friendly_name": "Porte"}},
  {"entity_id": "sensor.temperature_salon", "state": "21.5", "attributes": {"friendly_name": "Température du salon", "unit_of_measurement": "°C"}}
 ]}
EOF
rm -f "$ROOT/house.json.calls"; }
export LABO_HA_FAKE="$ROOT/house.json"
calls() { cat "$ROOT/house.json.calls" 2>/dev/null; }
allowed() { house; out=$(python3 "$L" "$@" 2>&1); rc=$?
  [ $rc -eq 0 ] && ok "permis : $*" || bad "permis attendu (rc=$rc) : $* — $out"; }
refused() { house; out=$(python3 "$L" "$@" 2>&1); rc=$?
  if [ $rc -eq 64 ] && [ -z "$(calls)" ]; then ok "refusé, rien n'est parti : $*"
  else bad "refus attendu (rc=$rc, appels: $(calls)) : $* — $out"; fi; }
has() { case $2 in *"$3"*) ok "$1";; *) bad "$1 — manque « $3 » dans : $2";; esac; }
lacks() { case $2 in *"$3"*) bad "$1 — « $3 » ne devrait pas y être";; *) ok "$1";; esac; }

say "lire"
house; out=$(python3 "$L" etat)
has "l'état montre ce qui est exposé" "$out" "light.bureau (Lumière du bureau) : on"
has "…avec ses attributs utiles" "$out" "brightness=200"
has "…et dit ce qui est pilotable" "$out" "light.bureau (Lumière du bureau) : on — brightness=200 [pilotable]"
lacks "…pas ce qui n'est pas exposé" "$out" "prise_des_serveurs"
lacks "…pas une entité désactivée" "$out" "light.vieille"
has "un capteur exposé se lit" "$out" "21.5 — unit_of_measurement=°C"
lacks "…mais n'est pas pilotable" "$(grep temperature_salon <<<"$out")" "[pilotable]"
lacks "stella se lit mais n'est pas pilotable" "$(grep switch.stella <<<"$out")" "[pilotable]"
out=$(python3 "$L" etat salon); has "filtre par pièce, sans accents" "$out" "light.salon_lampe"
lacks "…seulement le salon" "$out" "light.bureau"
out=$(python3 "$L" pieces); has "pièces : la lampe du salon (pièce héritée de l'appareil)" "$out" "Salon [piece:salon]"
lacks "pièces : stella n'y est pas" "$out" "switch.stella"

say "agir sur la maison"
allowed action light.turn_off light.bureau
has "…l'appel est parti" "$(calls)" '"entities": ["light.bureau"]'
has "…et l'état après est affiché" "$out" "light.bureau (Lumière du bureau) : off"
allowed action light.turn_on piece:salon brightness_pct=30
has "une pièce devient ses lumières pilotables" "$(calls)" '"entities": ["light.salon_lampe"]'
has "…avec les données, typées" "$(calls)" '"brightness_pct": 30'
allowed action light.turn_on piece:Sous-sol
has "le nom de la pièce marche aussi" "$(calls)" '"entities": ["light.sous_sol"]'
lacks "…et n'atteint pas la prise des serveurs" "$(calls)" "prise_des_serveurs"
allowed action switch.turn_on switch.purificateur
allowed action media_player.media_pause media_player.salon
allowed action script.meteo lieu=Montréal
has "un script permis rend sa réponse" "$out" '"fake": true'

say "refuser le labo et le reste"
refused action switch.turn_off switch.stella
refused action switch.turn_off piece:sous_sol
refused action light.turn_off light.prise_des_serveurs
refused action light.turn_off light.bureau light.prise_des_serveurs
refused action light.turn_off light.bureau switch.stella
refused action homeassistant.turn_off piece:sous_sol
refused action lock.unlock lock.porte
refused action button.press button.observateur_autoriser
refused action script.redemarrer_tout
refused action script.turn_on script.redemarrer_tout
refused action light.turn_off switch.purificateur
refused action light.delete light.bureau
refused action light.turn_off light.vieille
refused action light.turn_off light.nexiste_pas
refused action light.turn_off
refused action light.turn_off entity_id=switch.stella
refused action light.turn_off piece:grenier
refused action switch.turn_off switch.stella entity_id=light.bureau
refused etait
refused

printf '\n%d passed, %d failed\n' "$pass" "$failed"; [ "$failed" -eq 0 ]
