#!/usr/bin/env bash
# labo-lire — lire l'état d'un hôte du labo, sans pouvoir le modifier.
#
#   labo-lire <hôte> <commande> [arguments…]
#
# Pour Qwen Code, qui consulte le labo mais ne le change jamais (les
# changements restent à Claude) : `ssh` direct lui est refusé, et ceci est son
# seul chemin vers les hôtes. La commande passe par une LISTE BLANCHE de
# lectures ; tout le reste est refusé avant même d'ouvrir la connexion. Pas de
# sudo, pas de métacaractères du shell (; | & $ ` > < …) : la ligne arrive à
# l'hôte citée mot par mot, elle ne peut pas en enchaîner une autre.
#
# Code de sortie : celui de la commande distante ; 64 = refusé ici.
set -uo pipefail
SSH="${LABO_SSH:-ssh}"   # remplaçable pour les tests

deny() { echo "labo-lire : refusé — $*" >&2; exit 64; }
[ $# -ge 2 ] || deny "usage : labo-lire <hôte> <commande> [arguments…]"
host=$1; shift
[[ $host =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]] || deny "nom d'hôte invalide : $host"

for a in "$@"; do
  case $a in
    *[\;\|\&\$\`\>\<\(\)\{\}\\\!\*\?]*|*$'\n'*) deny "métacaractère dans « $a »";;
  esac
done
# Nothing that names a secret, wherever it sits on the line.
for a in "$@"; do
  case ${a,,} in
    *ssh/*|*.ssh*|*secret*|*token*|*passw*|*shadow*|*.kube*|*kubeconfig*|*.env|*/env|*credential*|*private*|*.key|*.pem|*keepass*|*.kdbx*)
      deny "« $a » ressemble à un secret";;
  esac
done

cmd=$1; shift
rest=" $* "
sub=${1:-}
only_flags() { for a in "$@"; do case $a in -*) ;; *) return 1;; esac; done; }
paths_ok() {   # file readers: absolute paths under these trees, or a bare number (-n 20)
  for a in "$@"; do
    case $a in -*) continue;; esac
    [[ $a =~ ^[0-9]+$ ]] && continue
    # No way back up out of an allowed tree (/var/log/../../home/…).
    case /$a/ in */../*) deny "« $a » : pas de .. dans un chemin";; esac
    case $a in
      /proc/*|/sys/*|/etc/*|/var/log/*|/run/*|/nix/var/nix/profiles/*|/boot/*) ;;
      # The fleet's scripts log to ~/logs, not /var/log: weekly-updates.log on
      # the jumphost is where a failed weekly run says why (unreadable before,
      # so the 2026-09-27 office bench could not find the cause in 5 min).
      /home/ludorl82/logs/*) ;;
      *) deny "« $a » : lecture permise sous /proc /sys /etc /var/log /run /boot ~/logs seulement";;
    esac
  done
}

case $cmd in
  uptime|uname|free|lscpu|lsusb|lspci|lsblk|nproc|who|w|sensors|nixos-version|findmnt|lsmod) ;;
  # These three WRITE when given an argument (set the name, set the clock).
  hostname|date) only_flags "$@" || deny "$cmd : sans argument (un argument le modifierait)"
    case $rest in *" -s"*|*" --set"*|*" -F"*|*" --file"*) deny "$cmd ne fait que lire ici";; esac ;;
  df|du|ss|ps|top|vmstat|iostat) [ "$cmd" = top ] && { set -- -bn1 "$@"; } ;;
  journalctl)
    case $rest in *" --vacuum"*|*" --rotate"*|*" --flush"*|*" --relinquish"*|*" --sync"*|*" --setup-keys"*|*" --update-catalog"*)
      deny "journalctl ne fait que lire ici";; esac ;;
  systemctl)
    case $sub in
      status|is-active|is-enabled|is-failed|is-system-running|list-units|list-timers|list-unit-files|list-sockets|show|cat|--failed|list-dependencies) ;;
      *) deny "systemctl $sub : seulement status, is-*, list-*, show, cat";;
    esac ;;
  ip)
    case $rest in *" add "*|*" del "*|*" delete "*|*" set "*|*" flush "*|*" change "*|*" replace "*|*" append "*|*" down "*|*" up "*)
      deny "ip ne fait que lire ici";; esac ;;
  nvidia-smi)
    only_flags "$@" || deny "nvidia-smi : options de lecture seulement"
    case $rest in *" -r "*|*" --gpu-reset"*|*" -pm"*|*" -pl"*|*" -c "*|*" -ac"*|*" -rac"*|*" -lgc"*|*" -rgc"*|*" --persistence"*|*" --power-limit"*|*" --compute-mode"*|*" -e "*|*" --ecc"*)
      deny "nvidia-smi ne fait que lire ici";; esac ;;
  zpool) case $sub in status|list|iostat) ;; *) deny "zpool $sub : seulement status, list, iostat";; esac ;;
  zfs) case $sub in list|get) ;; *) deny "zfs $sub : seulement list, get";; esac ;;
  mdadm) case $sub in --detail|-D|--query|-Q|--examine|-E) ;; *) deny "mdadm : seulement --detail, --query, --examine";; esac ;;
  smartctl) case $sub in -a|-H|-i|-A|--all|--health|--info|-x) ;; *) deny "smartctl : seulement la lecture";; esac ;;
  docker) case $sub in ps|logs|inspect|images|stats|info|version|top|port|df) [ "$sub" = stats ] && case $rest in *--no-stream*) ;; *) set -- stats --no-stream "${@:2}";; esac ;;
          *) deny "docker $sub : seulement ps, logs, inspect, images, stats, info, top, port, df";; esac ;;
  virsh) case $sub in list|dominfo|domstate|domblklist|domiflist|nodeinfo|nodememstats|vcpuinfo|net-list|pool-list|vol-list|dumpxml) ;;
          *) deny "virsh $sub : seulement la lecture";; esac ;;
  wg) case $sub in show) ;; *) deny "wg : seulement show";; esac ;;
  cat|head|tail|ls|stat|wc|grep|zcat|readlink|file)
    case $cmd in tail) case $rest in *" -f"*|*" --follow"*) deny "tail -f ne se termine jamais";; esac;; esac
    if [ "$cmd" = grep ]; then   # grep [options] PATTERN PATH…: the pattern is not a path
      args=(); pat=
      for a in "$@"; do case $a in -*) ;; *) [ -z "$pat" ] && { pat=1; continue; }; args+=("$a");; esac; done
      [ ${#args[@]} -gt 0 ] || deny "grep : donne un chemin (sous /proc /sys /etc /var/log /run /boot ~/logs)"
      paths_ok "${args[@]}"
    else
      paths_ok "$@"
    fi ;;
  *) deny "« $cmd » n'est pas dans la liste des lectures (voir scripts/labo-lire.sh)";;
esac

# Quote every word so the remote shell sees exactly this argv.
remote=$(printf '%q ' "$cmd" "$@")
exec $SSH -4 -n -o BatchMode=yes -o ConnectTimeout=10 "$host" -- "$remote"
