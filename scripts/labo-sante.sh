#!/usr/bin/env bash
# labo-sante — la santé du cluster k3s en une commande, pour un humain ou un agent.
#
# Imprime ce qui ne va PAS, rien d'autre : nœuds pas prêts ou cordonnés, pods
# qui ne sont ni Running ni Completed (ou Running avec des conteneurs pas
# prêts), avertissements des 30 dernières minutes. Tout va bien : une ligne le
# dit, avec les comptes. Lecture seule ; kubectl depuis la console.
set -uo pipefail
k() { kubectl --request-timeout=15s "$@"; }

nodes=$(k get nodes --no-headers 2>&1) || { echo "labo-sante : kubectl ne répond pas : $nodes"; exit 2; }
n_total=$(wc -l <<<"$nodes")
bad_nodes=$(awk '$2!="Ready"' <<<"$nodes")

pods=$(k get pods -A --no-headers 2>&1)
p_total=$(wc -l <<<"$pods")
# NAMESPACE NAME READY STATUS RESTARTS AGE
bad_pods=$(awk '{split($3,r,"/")} ($4!="Running" && $4!="Completed") || ($4=="Running" && r[1]!=r[2])' <<<"$pods")

since=$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)
warns=$(k get events -A --field-selector type=Warning -o jsonpath='{range .items[*]}{.lastTimestamp}{"\t"}{.involvedObject.namespace}/{.involvedObject.name}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' -v s="$since" '$1>=s' | sort -r | head -15 | cut -c1-220)

if [ -z "$bad_nodes" ] && [ -z "$bad_pods" ] && [ -z "$warns" ]; then
  echo "Cluster en santé : $n_total nœuds prêts, $p_total pods sans problème, aucun avertissement depuis 30 min."
  exit 0
fi
echo "Nœuds : $n_total, dont $( [ -n "$bad_nodes" ] && wc -l <<<"$bad_nodes" || echo 0 ) pas prêts ou cordonnés."
[ -n "$bad_nodes" ] && sed 's/^/  /' <<<"$bad_nodes"
echo "Pods : $p_total, dont $( [ -n "$bad_pods" ] && wc -l <<<"$bad_pods" || echo 0 ) en difficulté."
[ -n "$bad_pods" ] && sed 's/^/  /' <<<"$bad_pods" | head -20
if [ -n "$warns" ]; then
  echo "Avertissements des 30 dernières minutes :"
  sed 's/^/  /' <<<"$warns"
fi
