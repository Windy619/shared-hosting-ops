#!/usr/bin/env bash
# =============================================================================
# aide.sh - controle d'integrite AIDE, rapport et cycle de vie de la base.
#
# USAGE
#   aide.sh init      cree la base de reference (une seule fois)
#   aide.sh check     controle d'integrite, SANS jamais modifier la base
#   aide.sh update    accepte l'etat courant comme nouvelle reference
#   aide.sh status    etat de la base, empreinte, dernier controle
#
# CRON
#   # controle quotidien, lecture seule
#   0 4 * * *  /usr/local/bin/aide.sh check
#
#   `update` n'est JAMAIS appele par cron : c'est une decision humaine, prise
#   apres lecture du rapport. Voir la note de conception dans
#   aide-report.conf.example.
#
# CONFIGURATION
#   /etc/aide-report.conf (voir aide-report.conf.example)
# =============================================================================

set -euo pipefail

# Les rapports contiennent l'arborescence et les empreintes du serveur.
umask 077

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# Configuration
# =============================================================================
AIDE_BIN="${AIDE_BIN:-/usr/sbin/aide}"
AIDE_CONF="${AIDE_CONF:-/etc/aide.conf}"
AIDE_DB="${AIDE_DB:-/var/lib/aide/aide.db.gz}"
AIDE_DB_NEW="${AIDE_DB_NEW:-/var/lib/aide/aide.db.new.gz}"
REPORT_DIR="${REPORT_DIR:-/var/lib/aide/reports}"
DB_ARCHIVE_DIR="${DB_ARCHIVE_DIR:-/var/lib/aide/db-archive}"
KEEP_REPORTS="${KEEP_REPORTS:-30}"
KEEP_DB_ARCHIVES="${KEEP_DB_ARCHIVES:-10}"
MAIL_TO="${MAIL_TO:-}"
MAIL_FROM="${MAIL_FROM:-no-reply@localhost}"
MAIL_WHEN="${MAIL_WHEN:-always}"
MAX_REPORT_LINES="${MAX_REPORT_LINES:-200}"
USE_CHATTR="${USE_CHATTR:-0}"
# Charge un fichier de configuration UNIQUEMENT s'il est sur.
#
# Ce script tourne en root et `source` execute le contenu du fichier : une
# configuration inscriptible par un autre compte equivaut a une execution de
# code arbitraire en root.
safe_source() {
  local f="$1" owner mode
  [ -r "$f" ] || return 0

  owner="$(stat -c '%u' "$f" 2>/dev/null)" || return 0
  mode="$(stat -c '%a' "$f" 2>/dev/null)"  || return 0

  if [ "$(id -u)" -eq 0 ] && [ "$owner" != "0" ]; then
    printf 'ATTENTION : %s ignore (proprietaire non root)\n' "$f" >&2
    return 0
  fi
  # 0022 en octal = bit d'ecriture pour le groupe et pour les autres.
  if [ $(( 8#$mode & 0022 )) -ne 0 ]; then
    printf 'ATTENTION : %s ignore (inscriptible groupe/autres, mode %s)\n' "$f" "$mode" >&2
    return 0
  fi

  # shellcheck source=/dev/null
  . "$f"
}

for cfg in /etc/aide-report.conf "$SCRIPT_DIR/aide-report.conf"; do
  safe_source "$cfg"
done

# Le verrou vit a cote de la base AIDE, repertoire possede par root, et JAMAIS
# dans /var/lock : ce dernier pointe vers /run/lock, en mode 1777. Un compte
# non privilegie peut y deposer d'avance un lien symbolique du nom attendu ;
# « exec 9> » le suit et TRONQUE la cible, en root.
LOCK_FILE="${LOCK_FILE:-$(dirname "$AIDE_DB")/.aide-report.lock}"

# Format ISO 8601 : le tri lexicographique des noms est le tri chronologique.
# Avec %m-%d-%Y, rapports et bases archivees se classaient dans le desordre.
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
HOSTNAME_S="$(hostname)"
DB_HASH_FILE="$AIDE_DB.sha256"

REPORT_FILE=""

# =============================================================================
# Sorties
# =============================================================================
log()  { printf '%s [INFO] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { printf '%s [FATAL] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

usage() {
  sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# =============================================================================
# Garde-fous
# =============================================================================
require_env() {
  [ "$(id -u)" -eq 0 ] || die "ce script doit etre lance en root (lecture integrale du systeme de fichiers)"
  [ -x "$AIDE_BIN" ]   || die "binaire AIDE introuvable : $AIDE_BIN"
  [ -r "$AIDE_CONF" ]  || die "configuration AIDE illisible : $AIDE_CONF"
  mkdir -p "$REPORT_DIR" "$DB_ARCHIVE_DIR" "$(dirname "$AIDE_DB")"
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || { warn "flock absent : execution non protegee"; return 0; }
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "un controle AIDE est deja en cours ($LOCK_FILE)"
}

# =============================================================================
# Empreinte de la base de reference
# =============================================================================
# Un attaquant root peut regenerer la base et rendre AIDE aveugle. On ne peut
# pas l'en empecher depuis la machine surveillee, mais on peut le DETECTER :
# l'empreinte est enregistree a chaque `update` et verifiee a chaque `check`.
# Comme elle figure aussi dans chaque courriel, la boite mail tient lieu de
# copie hors-machine.
db_hash() {
  sha256sum "$AIDE_DB" 2>/dev/null | cut -d' ' -f1
}

store_db_hash() {
  db_hash > "$DB_HASH_FILE"
  chmod 600 "$DB_HASH_FILE"
}

check_db_hash() {
  local current expected
  current="$(db_hash)"

  if [ ! -f "$DB_HASH_FILE" ]; then
    printf 'empreinte de reference absente (premiere execution ?)\n'
    return 2
  fi

  expected="$(cat "$DB_HASH_FILE")"
  if [ "$current" = "$expected" ]; then
    printf 'base de reference intacte (%s)\n' "${current:0:16}..."
    return 0
  fi

  printf 'BASE DE REFERENCE MODIFIEE HORS PROCEDURE\n'
  printf '  attendue : %s\n' "$expected"
  printf '  trouvee  : %s\n' "$current"
  return 1
}

db_immutable() {
  [ "$USE_CHATTR" = "1" ] || return 0
  command -v chattr >/dev/null 2>&1 || { warn "chattr absent : base non protegee"; return 0; }
  chattr "$1" "$AIDE_DB" 2>/dev/null || warn "chattr $1 a echoue (systeme de fichiers non compatible ?)"
}

# =============================================================================
# Rotation
# =============================================================================
rotate() {
  local dir="$1" pattern="$2" keep="$3" f i=0
  local files=()

  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" | sort -r)

  [ "${#files[@]}" -gt 0 ] || return 0

  for f in "${files[@]}"; do
    i=$((i + 1))
    [ "$i" -le "$keep" ] && continue
    rm -f "$f"
  done
  log "rotation $dir : $((i > keep ? i - keep : 0)) fichier(s) supprime(s)"
}

# =============================================================================
# Rapport par e-mail
# =============================================================================
send_report() {
  local subject="$1" summary="$2" body

  [ -n "$MAIL_TO" ] || { log "MAIL_TO vide : aucun envoi"; return 0; }

  # Le sujet est concatene dans des en-tetes SMTP : un retour a la ligne y
  # injecterait un en-tete arbitraire.
  subject="$(printf '%s' "$subject" | tr -d '\r\n')"

  body="$(
    printf '%s\n\n' "$summary"
    if [ -n "$REPORT_FILE" ] && [ -s "$REPORT_FILE" ]; then
      printf -- '--- Extrait du rapport (%s premieres lignes) ---\n' "$MAX_REPORT_LINES"
      head -n "$MAX_REPORT_LINES" "$REPORT_FILE"
      if [ "$(wc -l < "$REPORT_FILE")" -gt "$MAX_REPORT_LINES" ]; then
        printf '\n[...] rapport tronque.\n'
      fi
      printf '\nRapport complet : %s\n' "$REPORT_FILE"
    fi
  )"

  if command -v sendmail >/dev/null 2>&1; then
    {
      printf 'From: %s\n' "$MAIL_FROM"
      printf 'To: %s\n' "$MAIL_TO"
      printf 'Subject: %s\n' "$subject"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf 'MIME-Version: 1.0\n'
      printf '\n%s\n' "$body"
    } | sendmail -t
  elif command -v mail >/dev/null 2>&1; then
    # `mail -a` designe une piece jointe avec bsd-mailx mais un EN-TETE
    # supplementaire avec s-nail/heirloom : le comportement changeait
    # silencieusement selon la distribution. On s'en passe.
    printf '%s\n' "$body" | mail -s "$subject" "$MAIL_TO"
  else
    warn "aucun agent de courrier : rapport non envoye"
    return 0
  fi
  log "rapport envoye a $MAIL_TO"
}

# =============================================================================
# Interpretation du code de sortie d'AIDE
# =============================================================================
# man aide : "the exit status is defined as
#   1 * (new files detected?) + 2 * (removed files detected?)
#   + 4 * (changed files detected?)"
# et 14 a 19 signalent une erreur d'execution.
#
# Fonctions isolees pour etre testables sans lancer AIDE (voir tests/aide.bats).
classify_aide_rc() {
  local rc="$1"
  if   [ "$rc" -ge 14 ]; then printf 'ERREUR'
  elif [ "$rc" -eq 0 ];  then printf 'OK'
  else                        printf 'ALERTE'
  fi
}

describe_aide_rc() {
  local rc="$1" d=""
  if [ "$rc" -ge 14 ]; then
    printf "AIDE a echoue (code %s : erreur d'execution, pas un resultat d'analyse)." "$rc"
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'Aucune difference detectee.'
    return 0
  fi
  d="Differences detectees (code $rc) :"
  if (( rc & 1 )); then d="$d"$'\n'"  - nouveaux fichiers"; fi
  if (( rc & 2 )); then d="$d"$'\n'"  - fichiers supprimes"; fi
  if (( rc & 4 )); then d="$d"$'\n'"  - fichiers modifies"; fi
  printf '%s' "$d"
}

# =============================================================================
# Commandes
# =============================================================================
cmd_init() {
  require_env
  acquire_lock

  if [ -f "$AIDE_DB" ]; then
    die "une base existe deja : $AIDE_DB
  Pour la remplacer deliberement : $SCRIPT_NAME update"
  fi

  log "creation de la base de reference (peut durer plusieurs minutes)..."
  "$AIDE_BIN" -c "$AIDE_CONF" --init

  [ -f "$AIDE_DB_NEW" ] || die "AIDE n'a pas produit $AIDE_DB_NEW"
  mv -f "$AIDE_DB_NEW" "$AIDE_DB"
  chmod 600 "$AIDE_DB"
  store_db_hash
  db_immutable +i

  log "base creee : $AIDE_DB"
  log "empreinte  : $(db_hash)"
  log ""
  log "Conservez cette empreinte hors de la machine : elle permet de detecter"
  log "une regeneration frauduleuse de la base."
}

cmd_check() {
  require_env
  acquire_lock

  [ -f "$AIDE_DB" ] || die "aucune base de reference : lancez d'abord $SCRIPT_NAME init"

  REPORT_FILE="$REPORT_DIR/aide-$STAMP.txt"

  local hash_msg hash_rc=0
  hash_msg="$(check_db_hash)" || hash_rc=$?

  {
    printf 'Controle AIDE - %s\n' "$HOSTNAME_S"
    printf 'Date      : %s\n' "$STAMP"
    printf 'Base      : %s\n' "$AIDE_DB"
    printf 'Empreinte : %s\n' "$(db_hash)"
    printf '\n%s\n' "$hash_msg"
    printf '\n---------------------- Debut du controle ----------------------\n\n'
  } > "$REPORT_FILE"

  # Le code de sortie d'AIDE est la source de verite, et non la presence de
  # la chaine "AIDE found differences" dans la sortie :
  #   0            conforme
  #   1*nouveaux + 2*supprimes + 4*modifies
  #   14 a 19      erreur d'execution
  # C'est ce qui permet de distinguer « aucune difference » d'« AIDE a
  # echoue », que la version precedente confondait.
  local rc=0
  "$AIDE_BIN" -c "$AIDE_CONF" --check >> "$REPORT_FILE" 2>&1 || rc=$?

  printf '\n----------------------- Fin du controle -----------------------\n' >> "$REPORT_FILE"
  chmod 600 "$REPORT_FILE"

  local status subject summary details
  status="$(classify_aide_rc "$rc")"
  details="$(describe_aide_rc "$rc")"

  # Une base modifiee hors procedure prime sur tout le reste : c'est le
  # scenario ou AIDE ne voit plus rien.
  if [ "$hash_rc" -eq 1 ]; then
    status="COMPROMISSION POSSIBLE"
    details="$hash_msg"$'\n\n'"$details"
  fi

  subject="[$status] AIDE $HOSTNAME_S - $STAMP"
  summary="$(printf 'Controle AIDE sur %s\nDate : %s\n\n%s\n\nBase      : %s\nEmpreinte : %s' \
    "$HOSTNAME_S" "$STAMP" "$details" "$AIDE_DB" "$(db_hash)")"

  log "$status (code AIDE $rc)"
  log "rapport : $REPORT_FILE"

  if [ "$MAIL_WHEN" = "always" ] || [ "$status" != "OK" ]; then
    send_report "$subject" "$summary"
  fi

  rotate "$REPORT_DIR" 'aide-*.txt' "$KEEP_REPORTS"

  # La base n'est PAS mise a jour ici, volontairement : sinon une intrusion
  # deviendrait la nouvelle reference des le lendemain.
  [ "$rc" -eq 0 ] && [ "$hash_rc" -ne 1 ]
}

cmd_update() {
  require_env
  acquire_lock

  [ -f "$AIDE_DB" ] || die "aucune base a mettre a jour : lancez $SCRIPT_NAME init"

  if [ "${CONFIRM_UPDATE:-}" != "UPDATE" ]; then
    cat <<EOF

  MISE A JOUR DE LA BASE DE REFERENCE

  L'etat actuel du systeme de fichiers deviendra la nouvelle reference.
  Toute modification non encore examinee sera donc validee comme legitime.

  Examinez d'abord le dernier rapport :
      $SCRIPT_NAME status

  Puis, si les differences sont bien attendues :
      CONFIRM_UPDATE=UPDATE $SCRIPT_NAME update

EOF
    exit 1
  fi

  local archive="$DB_ARCHIVE_DIR/aide.db-$STAMP.gz"
  cp -p "$AIDE_DB" "$archive"
  chmod 600 "$archive"
  log "base precedente archivee : $archive"

  db_immutable -i

  log "mise a jour de la base..."
  local rc=0
  "$AIDE_BIN" -c "$AIDE_CONF" --update >/dev/null 2>&1 || rc=$?
  [ "$rc" -lt 14 ] || die "AIDE a echoue (code $rc) : base inchangee"

  [ -f "$AIDE_DB_NEW" ] || die "AIDE n'a pas produit $AIDE_DB_NEW : base inchangee"
  mv -f "$AIDE_DB_NEW" "$AIDE_DB"
  chmod 600 "$AIDE_DB"
  store_db_hash
  db_immutable +i

  rotate "$DB_ARCHIVE_DIR" 'aide.db-*.gz' "$KEEP_DB_ARCHIVES"

  log "nouvelle base en place"
  log "empreinte : $(db_hash)"

  send_report "[MAJ] AIDE $HOSTNAME_S - base de reference mise a jour" \
    "$(printf 'La base de reference AIDE de %s a ete mise a jour.\n\nDate      : %s\nPar       : %s\nArchive   : %s\nEmpreinte : %s' \
        "$HOSTNAME_S" "$STAMP" "${SUDO_USER:-root}" "$archive" "$(db_hash)")"
}

cmd_status() {
  require_env

  printf 'Hote      : %s\n' "$HOSTNAME_S"
  printf 'Base      : %s\n' "$AIDE_DB"

  if [ -f "$AIDE_DB" ]; then
    printf 'Taille    : %s\n' "$(du -h "$AIDE_DB" | cut -f1)"
    printf 'Modifiee  : %s\n' "$(date -u -r "$AIDE_DB" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    printf 'Empreinte : %s\n' "$(db_hash)"
    printf 'Integrite : %s\n' "$(check_db_hash || true)"
  else
    printf 'Base absente - lancez %s init\n' "$SCRIPT_NAME"
    return 1
  fi

  local last
  last="$(find "$REPORT_DIR" -maxdepth 1 -type f -name 'aide-*.txt' 2>/dev/null | sort -r | head -n 1)"
  printf '\nDernier rapport : %s\n' "${last:-aucun}"
  if [ -n "$last" ]; then
    printf '\n'
    head -n 12 "$last" | sed 's/^/  /'
  fi

  printf '\nRapports conserves : %s\n' \
    "$(find "$REPORT_DIR" -maxdepth 1 -type f -name 'aide-*.txt' 2>/dev/null | wc -l)"
  printf 'Bases archivees    : %s\n' \
    "$(find "$DB_ARCHIVE_DIR" -maxdepth 1 -type f -name 'aide.db-*.gz' 2>/dev/null | wc -l)"
}

# =============================================================================
# Point d'entree
# =============================================================================
main() {
  local cmd="${1:-}"
  case "$cmd" in
    init)          cmd_init ;;
    check)         cmd_check ;;
    update)        cmd_update ;;
    status)        cmd_status ;;
    -h|--help|help) usage 0 ;;
    # Sans argument, on sort en ERREUR plutot qu'en affichant l'aide : une
    # ancienne crontab appelant « aide.sh » tout court ne doit pas devenir un
    # cron silencieusement inoperant. Cron enverra la sortie d'erreur.
    '')            printf 'Aucune commande. La crontab doit appeler : %s check\n\n' "$SCRIPT_NAME" >&2
                   usage 1 ;;
    *)             printf 'Commande inconnue : %s\n\n' "$cmd" >&2; usage 1 ;;
  esac
}

# Le garde permet de sourcer ce fichier pour tester ses fonctions (bats)
# sans declencher l'execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
