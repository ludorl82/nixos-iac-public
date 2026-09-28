# kp-sync -- move a KeePass database between this Mac and the WebDAV server.
#
# WHY THIS EXISTS. KeePassXC cannot open a WebDAV URL. It has no remote sync
# either, in any released version -- 2.7.12 is current and the feature simply
# is not there. KeePass 2.x on Windows does speak WebDAV, which is why the
# Apache rules in k3s-iac allow its temp shape, but on macOS it needs Mono and
# Mono's native drawing backend is unfinished: the main window dies on the
# first text field. So the file has to be carried, and this carries it.
#
# WHY NOT A FINDER MOUNT. Apache answers PROPFIND on / with 403 by design --
# only the named databases are reachable. The Finder lists the root to mount,
# so it cannot. It would also try to write .DS_Store and ._ files, which are
# refused too. Measured, not assumed.
#
# THE GUARD. Both directions refuse rather than overwrite:
#
#   push  sends If-Match with the ETag seen at the last sync. If the phone or
#         another machine wrote since, Apache answers 412 and nothing is lost.
#   pull  compares the local file against its hash at the last sync. If it
#         changed here, pulling would throw those edits away, so it stops.
#
# ETAGS HARDEN. Apache marks an ETag weak (W/"...") for about a second after a
# write, and If-Match uses strong comparison, so a weak tag never matches. We
# wait for the strong form rather than record a tag that can never be used.
# If-Unmodified-Since is NOT an alternative here: it answered 412 even for the
# exact Last-Modified the server had just sent.
#
# THE PASSWORD never appears in the repository, in the environment, or in the
# process list. It comes from the macOS Keychain and reaches curl through a
# config file on stdin.

BASE="${KP_BASE:-https://vault.family.example}"
DB="${KP_DB:-ludo}"
KP_USER="${KP_USER:-vault-user}"
KEYCHAIN="${KP_KEYCHAIN:-vault.family.example}"
SECURITY="${KP_SECURITY:-/usr/bin/security}"

DATA_DIR="${KP_DATA_DIR:-$HOME/.local/share/keepass}"
STATE_DIR="${KP_STATE_DIR:-$HOME/.local/state/keepass}"
LOCAL="$DATA_DIR/$DB.kdbx"
ETAG_FILE="$STATE_DIR/$DB.etag"
SHA_FILE="$STATE_DIR/$DB.sha256"
URL="$BASE/$DB.kdbx"

die() { printf 'kp-sync: %s\n' "$1" >&2; exit 1; }

# Feed credentials through stdin so they never reach the process list.
# Two DIFFERENT failures look alike here and must not be reported alike.
# errSecInteractionNotAllowed (36) means the entry EXISTS and the keychain
# wants to ask the user before handing the secret over -- which it cannot do
# without a window, so it fails outright over SSH. Reporting that as "absent"
# sends you off to re-add an entry that is already there.
kp_curl() {
  local pw rc
  pw=$("$SECURITY" find-generic-password -s "$KEYCHAIN" -a "$KP_USER" -w 2>/dev/null) || {
    rc=$?
    if [ "$rc" -eq 36 ]; then
      die "le trousseau refuse de livrer le mot de passe sans confirmation (code 36).
L'entree EXISTE, elle n'est simplement pas encore autorisee pour ce programme.
Relance cette commande dans un terminal SUR le Mac -- pas par SSH, il n'y a
pas de fenetre possible -- et reponds « Toujours autoriser »."
    fi
    die "mot de passe absent du trousseau (code $rc). Ajoute-le une fois :
  security add-generic-password -s $KEYCHAIN -a $KP_USER -w
Le mot de passe est dans l'entree KeePass intitulee « Keepass Server »."
  }
  printf 'user = "%s:%s"\n' "$KP_USER" "$pw" | curl --config - --silent --show-error "$@"
}

# A KDBX file starts with 03 d9 a2 9a. Anything else is an error page, a
# truncated transfer, or a half-written file -- never upload or install it.
kdbx_ok() {
  [ -s "$1" ] || return 1
  [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = "03d9a29a" ]
}

hash_of() { sha256sum "$1" | cut -d' ' -f1; }

# Return the STRONG ETag, waiting out the weak window that follows a write.
strong_etag() {
  local tag tries=0
  while [ "$tries" -lt 12 ]; do
    tries=$((tries + 1))
    tag=$(kp_curl --fail -m 30 -I "$URL" | tr -d '\r' \
          | awk -F': ' 'tolower($1)=="etag" {print $2}')
    case "$tag" in
      'W/'*) sleep 1 ;;
      '"'*)  printf '%s' "$tag"; return 0 ;;
      *)     return 1 ;;
    esac
  done
  return 1
}

record_state() {
  strong_etag > "$ETAG_FILE" || die "le gaming-01 n'a pas donne d'ETag exploitable"
  hash_of "$LOCAL" > "$SHA_FILE"
}

cmd_pull() {
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  mkdir -p "$DATA_DIR" "$STATE_DIR"

  local tmp
  tmp=$(mktemp "$DATA_DIR/.$DB.pull.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT

  kp_curl --fail -m 180 -o "$tmp" "$URL" \
    || die "telechargement refuse par le gaming-01"
  kdbx_ok "$tmp" || die "ce qui est arrive n'est pas une base KeePass -- rien n'a ete installe"

  # Refuse to discard local edits that were never pushed.
  if [ -f "$LOCAL" ] && [ -s "$SHA_FILE" ] && [ "$force" -eq 0 ]; then
    if [ "$(hash_of "$LOCAL")" != "$(cat "$SHA_FILE")" ]; then
      die "la copie locale a change depuis la derniere synchro.
Televerse-la d'abord avec kp-push, ou jette-la avec : kp-pull --force"
    fi
  fi

  [ -f "$LOCAL" ] && cp -p "$LOCAL" "$DATA_DIR/$DB.$(date +%Y%m%d-%H%M%S).bak"
  mv "$tmp" "$LOCAL"
  trap - EXIT
  record_state
  printf 'kp-sync: %s recuperee (%s octets)\n' "$LOCAL" "$(wc -c < "$LOCAL" | tr -d ' ')"
}

cmd_push() {
  [ -f "$LOCAL" ] || die "aucune copie locale : lance kp-pull d'abord"
  kdbx_ok "$LOCAL" || die "la copie locale n'est pas une base KeePass valide -- rien n'a ete envoye"
  [ -s "$ETAG_FILE" ] || die "aucun ETag enregistre : lance kp-pull d'abord"

  local code
  code=$(kp_curl -o /dev/null -w '%{http_code}' -m 300 \
         -H "If-Match: $(cat "$ETAG_FILE")" --upload-file "$LOCAL" "$URL")
  case "$code" in
    2*) ;;
    412) die "le gaming-01 a une version PLUS RECENTE que celle que tu as recuperee.
Rien n'a ete ecrase. Fusionne d'abord : ouvre la base locale dans KeePassXC,
Base de donnees > Fusionner depuis une base, en pointant une copie fraiche." ;;
    401|403) die "refuse a l'authentification ($code). Attention : le verrou du gaming-01
se declenche a 15 echecs. Verifie l'entree du trousseau avant de reessayer." ;;
    *) die "reponse inattendue du gaming-01 : $code" ;;
  esac
  record_state
  printf 'kp-sync: %s televersee\n' "$DB.kdbx"
}

cmd_status() {
  printf '  base distante   %s\n' "$URL"
  printf '  copie locale    %s\n' "$([ -f "$LOCAL" ] && echo "$LOCAL" || echo 'absente')"
  if [ -f "$LOCAL" ] && [ -s "$SHA_FILE" ]; then
    if [ "$(hash_of "$LOCAL")" = "$(cat "$SHA_FILE")" ]; then
      printf '  etat local      identique a la derniere synchro\n'
    else
      printf '  etat local      MODIFIE depuis la derniere synchro (kp-push)\n'
    fi
  fi
  local remote
  remote=$(strong_etag 2>/dev/null || echo '')
  if [ -n "$remote" ] && [ -s "$ETAG_FILE" ]; then
    if [ "$remote" = "$(cat "$ETAG_FILE")" ]; then
      printf '  etat distant    inchange depuis la derniere synchro\n'
    else
      printf '  etat distant    MODIFIE ailleurs depuis la derniere synchro (kp-pull)\n'
    fi
  fi
}

case "${1:-}" in
  pull)   shift; cmd_pull "$@" ;;
  push)   shift; cmd_push "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) die "usage : kp-sync pull [--force] | push | status   (ou kp-pull / kp-push)" ;;
esac
