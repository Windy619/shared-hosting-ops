#!/usr/bin/env bash
# =============================================================================
# docker_backup.sh - sauvegarde des volumes Docker, avec verification et
#                    chemin de restauration.
#
# USAGE
#   docker_backup.sh daily|weekly|monthly     effectue une sauvegarde
#   docker_backup.sh list                     liste les sauvegardes presentes
#   docker_backup.sh verify <repertoire>      controle l'integrite d'une sauvegarde
#   docker_backup.sh restore <repertoire>     restaure les volumes (DESTRUCTIF)
#
# CRON
#   Le palier est un ARGUMENT, jamais deduit de l'heure courante : c'est le
#   role de cron de decider quand. Deduire le palier de `date +%H` rendait la
#   sauvegarde silencieusement inoperante des que la machine avait redemarre
#   ou que cron decalait d'une minute.
#
#     0 2  * * 1-6  /usr/local/bin/docker_backup.sh daily
#     0 2  * * 7    /usr/local/bin/docker_backup.sh weekly
#     0 3  1 * *    /usr/local/bin/docker_backup.sh monthly
#
#   Avec systemd, preferer des timers OnCalendar + Persistent=true, qui
#   rattrapent les executions manquees.
#
# CONFIGURATION
#   /etc/docker-backup.conf (voir docker-backup.conf.example)
# =============================================================================

set -euo pipefail

# Les archives peuvent contenir des donnees applicatives sensibles : aucun
# acces pour le groupe ni pour les autres.
umask 077

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# Configuration
# =============================================================================
CONTAINERS="${CONTAINERS:-}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/docker}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
STOP_MODE="${STOP_MODE:-pause}"
PRE_BACKUP_CMD="${PRE_BACKUP_CMD:-}"
POST_BACKUP_CMD="${POST_BACKUP_CMD:-}"
BACKUP_IMAGE="${BACKUP_IMAGE:-0}"
ENCRYPT="${ENCRYPT:-0}"
GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:-}"
RSYNC_DEST="${RSYNC_DEST:-}"
RSYNC_OPTS="${RSYNC_OPTS:--az}"
MAIL_TO="${MAIL_TO:-}"
MAIL_FROM="${MAIL_FROM:-no-reply@localhost}"
MAIL_WHEN="${MAIL_WHEN:-onerror}"

# Charge un fichier de configuration UNIQUEMENT s'il est sur.
#
# Ce script tourne en root. `source` execute son contenu : un fichier de
# configuration inscriptible par un autre compte est donc une execution de
# code arbitraire en root. Le cas se presente des que le depot est clone dans
# un repertoire partage par une equipe et lance par cron.
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

for cfg in /etc/docker-backup.conf "$SCRIPT_DIR/docker-backup.conf"; do
  safe_source "$cfg"
done

# Format ISO 8601 : le tri lexicographique des noms EST le tri chronologique.
# Avec %d-%m-%Y, "01-12-2025" se classait avant "02-01-2024", et la rotation
# supprimait donc une sauvegarde arbitraire - parfois la plus recente.
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
DAY="$(date -u +%Y-%m-%d)"

LOG_DIR="$BACKUP_ROOT/logs"
LOG_FILE="$LOG_DIR/$DAY.log"

# Le verrou vit sous BACKUP_ROOT, que ce script cree et possede, et JAMAIS
# dans /var/lock : sur Linux moderne /var/lock pointe vers /run/lock, en mode
# 1777. Un compte non privilegie peut y deposer d'avance un lien symbolique
# du nom attendu ; « exec 9> » le suit et TRONQUE la cible, en root.
LOCK_FILE="${LOCK_FILE:-$BACKUP_ROOT/.docker-backup.lock}"

REPORT=()
FAILURES=0
PAUSED_CONTAINER=""
STOPPED_CONTAINER=""

# =============================================================================
# Journalisation
# =============================================================================
_log() {
  local level="$1"; shift
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$level] $*"
  printf '%s\n' "$line"
  [ -d "$LOG_DIR" ] && printf '%s\n' "$line" >> "$LOG_FILE"
  return 0
}
info() { _log INFO "$*"; }
warn() { _log WARN "$*" >&2; }
err()  { _log ERROR "$*" >&2; FAILURES=$((FAILURES + 1)); }
die()  { _log FATAL "$*" >&2; exit 1; }
say()  { REPORT+=("$*"); }

usage() {
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# =============================================================================
# Garde-fous
# =============================================================================
require_tools() {
  local t
  for t in docker tar gzip; do
    command -v "$t" >/dev/null 2>&1 || die "outil requis absent : $t"
  done
  docker info >/dev/null 2>&1 || die "le demon Docker ne repond pas (droits ?)"
}

# Un deuxieme passage concurrent corromprait les archives en cours d'ecriture
# et fausserait la rotation.
acquire_lock() {
  command -v flock >/dev/null 2>&1 || { warn "flock absent : execution non protegee"; return 0; }
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "une sauvegarde est deja en cours ($LOCK_FILE)"
}

# =============================================================================
# Cycle de vie du conteneur
# =============================================================================
# Sans precaution, un volume est copie pendant que le conteneur y ecrit :
# l'archive obtenue est incoherente et, pour une base de donnees, illisible.
freeze_container() {
  local c="$1"
  case "$STOP_MODE" in
    pause)
      docker pause "$c" >/dev/null && PAUSED_CONTAINER="$c" \
        && info "  conteneur fige (pause)"
      ;;
    stop)
      docker stop "$c" >/dev/null && STOPPED_CONTAINER="$c" \
        && info "  conteneur arrete"
      ;;
    none)
      warn "  STOP_MODE=none : archive potentiellement incoherente"
      ;;
    *)
      die "STOP_MODE invalide : $STOP_MODE (pause, stop ou none)"
      ;;
  esac
}

thaw_container() {
  if [ -n "$PAUSED_CONTAINER" ]; then
    docker unpause "$PAUSED_CONTAINER" >/dev/null 2>&1 || warn "  unpause echoue : $PAUSED_CONTAINER"
    PAUSED_CONTAINER=""
  fi
  if [ -n "$STOPPED_CONTAINER" ]; then
    docker start "$STOPPED_CONTAINER" >/dev/null 2>&1 || warn "  redemarrage echoue : $STOPPED_CONTAINER"
    STOPPED_CONTAINER=""
  fi
}

# Le conteneur doit repartir meme si le script echoue ou est interrompu.
on_exit() {
  local rc=$?
  thaw_container
  return $rc
}
trap on_exit EXIT
trap 'die "interrompu"' INT TERM

# =============================================================================
# Sauvegarde
# =============================================================================
container_volumes() {
  docker inspect "$1" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null \
    | sed '/^$/d'
}

safe_name() {
  printf '%s' "$1" | sed 's#^/##; s#[/ ]#_#g; s#[^A-Za-z0-9._-]#-#g'
}

# Archive un repertoire en une seule passe. L'ancienne version faisait
# cp -r vers un dossier temporaire, puis tar dessus, puis rm -rf : deux fois
# l'espace disque et deux fois les entrees/sorties pour le meme resultat.
archive_dir() {
  local src="$1" dest="$2"
  tar -C "$src" -czf "$dest" . 2>/dev/null
}

verify_archive() {
  local f="$1"
  case "$f" in
    *.gpg) return 0 ;;   # chiffre : verifie avant chiffrement
    *)     tar -tzf "$f" >/dev/null 2>&1 ;;
  esac
}

encrypt_file() {
  local f="$1"
  [ "$ENCRYPT" = "1" ] || return 0
  command -v gpg >/dev/null 2>&1 || { err "ENCRYPT=1 mais gpg est absent"; return 1; }
  [ -r "$GPG_PASSPHRASE_FILE" ] || { err "passphrase illisible : $GPG_PASSPHRASE_FILE"; return 1; }

  gpg --batch --quiet --yes --symmetric --cipher-algo AES256 \
      --passphrase-file "$GPG_PASSPHRASE_FILE" \
      --output "$f.gpg" "$f" || { err "chiffrement echoue : $(basename "$f")"; return 1; }
  rm -f "$f"
  return 0
}

backup_container() {
  local container="$1" dest="$2"
  local vol_dir="$dest/volumes/$container"
  local n=0 ok_count=0

  info "conteneur $container"

  if ! docker inspect "$container" >/dev/null 2>&1; then
    err "  conteneur introuvable : $container"
    say "  $container : ECHEC (conteneur introuvable)"
    return 1
  fi

  mkdir -p "$vol_dir"

  # Metadonnees : de quoi reconstruire l'environnement sans sauvegarder l'image.
  docker inspect "$container" > "$dest/meta-$container.json" 2>/dev/null || true
  docker inspect "$container" --format '{{.Config.Image}}' > "$dest/image-$container.txt" 2>/dev/null || true

  [ -n "$PRE_BACKUP_CMD" ] && {
    info "  pre-backup dans le conteneur"
    # shellcheck disable=SC2086  # commande fournie par la configuration
    docker exec "$container" $PRE_BACKUP_CMD || err "  pre-backup echoue"
  }

  freeze_container "$container"

  while IFS= read -r src; do
    [ -n "$src" ] || continue
    if [ ! -d "$src" ]; then
      info "  ignore (pas un repertoire) : $src"
      continue
    fi

    n=$((n + 1))
    local name archive
    name="$(safe_name "$src")"
    archive="$vol_dir/${n}-${name}.tar.gz"

    if ! archive_dir "$src" "$archive"; then
      err "  archivage echoue : $src"
      rm -f "$archive"
      continue
    fi
    if ! verify_archive "$archive"; then
      err "  archive illisible : $(basename "$archive")"
      rm -f "$archive"
      continue
    fi

    sha256sum "$archive" >> "$dest/SHA256SUMS" 2>/dev/null || true
    encrypt_file "$archive" || true

    ok_count=$((ok_count + 1))
    info "  volume $src -> $(basename "$archive") ($(du -h "$archive"* 2>/dev/null | head -1 | cut -f1))"
  done < <(container_volumes "$container")

  thaw_container

  [ -n "$POST_BACKUP_CMD" ] && {
    # shellcheck disable=SC2086  # commande fournie par la configuration
    docker exec "$container" $POST_BACKUP_CMD || warn "  post-backup echoue"
  }

  # L'image n'est sauvegardee que sur demande : elle est reconstructible
  # depuis le registre, et son archivage quotidien pese plus lourd que
  # l'ensemble des donnees utiles.
  if [ "$BACKUP_IMAGE" = "1" ]; then
    # docker commit refuse les majuscules dans un tag : la version precedente
    # ne normalisait le nom que dans la branche quotidienne, si bien que les
    # sauvegardes hebdomadaires et mensuelles echouaient sur un conteneur
    # comportant une majuscule.
    local tag
    tag="backup_$(printf '%s' "$container" | tr '[:upper:]' '[:lower:]')_$STAMP"
    if docker commit "$container" "$tag" >/dev/null 2>&1; then
      if docker save "$tag" | gzip -1 > "$dest/image-$container.tar.gz"; then
        info "  image sauvegardee ($(du -h "$dest/image-$container.tar.gz" | cut -f1))"
      else
        err "  docker save echoue"
        rm -f "$dest/image-$container.tar.gz"
      fi
      docker rmi "$tag" >/dev/null 2>&1 || warn "  image temporaire $tag non supprimee"
    else
      err "  docker commit echoue"
    fi
  fi

  if [ "$n" -eq 0 ]; then
    warn "  aucun volume monte"
    say "  $container : aucun volume"
  elif [ "$ok_count" -eq "$n" ]; then
    say "  $container : $ok_count/$n volume(s) OK"
  else
    say "  $container : $ok_count/$n volume(s) - ECHECS"
    return 1
  fi
  return 0
}

# =============================================================================
# Rotation
# =============================================================================
rotate() {
  local tier_dir="$1" keep="$2" d i=0
  local dirs=()

  for d in "$tier_dir"/*/; do
    [ -d "$d" ] || continue
    dirs+=("${d%/}")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0

  # Noms horodates ISO : tri lexicographique inverse = du plus recent au plus
  # ancien. Plus de boucle `while` susceptible de tourner indefiniment si un
  # rm echoue : on parcourt une liste finie.
  mapfile -t dirs < <(printf '%s\n' "${dirs[@]}" | sort -r)

  for d in "${dirs[@]}"; do
    i=$((i + 1))
    [ "$i" -le "$keep" ] && continue
    if rm -rf "$d"; then
      info "rotation : $(basename "$d") supprimee"
    else
      err "rotation : suppression impossible de $d"
    fi
  done
}

# =============================================================================
# Copie hors-site
# =============================================================================
offsite_sync() {
  [ -n "$RSYNC_DEST" ] || return 0
  command -v rsync >/dev/null 2>&1 || { err "RSYNC_DEST defini mais rsync absent"; return 1; }

  info "copie hors-site vers $RSYNC_DEST"
  # shellcheck disable=SC2086  # options fournies par la configuration
  if rsync $RSYNC_OPTS "$BACKUP_ROOT/" "$RSYNC_DEST"; then
    say "  copie hors-site : OK"
  else
    err "copie hors-site echouee"
    say "  copie hors-site : ECHEC"
    return 1
  fi
}

# =============================================================================
# Rapport
# =============================================================================
send_report() {
  local status="$1" subject body

  [ -n "$MAIL_TO" ] || return 0
  [ "$MAIL_WHEN" = "always" ] || [ "$status" != "OK" ] || return 0

  # Le sujet est concatene dans des en-tetes SMTP : tout retour a la ligne
  # injecterait un en-tete arbitraire. On le neutralise.
  subject="[$status] Sauvegarde Docker $TIER - $(hostname) - $DAY"
  subject="$(printf '%s' "$subject" | tr -d '\r\n')"

  body="$(printf '%s\n' "${REPORT[@]}")"

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
    printf '%s\n' "$body" | mail -s "$subject" "$MAIL_TO"
  else
    warn "aucun agent de courrier : rapport non envoye"
  fi
}

# =============================================================================
# Commandes
# =============================================================================
cmd_backup() {
  TIER="$1"
  local keep tier_dir dest

  case "$TIER" in
    daily)   keep="$KEEP_DAILY"   ;;
    weekly)  keep="$KEEP_WEEKLY"  ;;
    monthly) keep="$KEEP_MONTHLY" ;;
    *) die "palier inconnu : $TIER" ;;
  esac

  [ -n "$CONTAINERS" ] || die "aucun conteneur configure (CONTAINERS)"

  require_tools
  acquire_lock

  tier_dir="$BACKUP_ROOT/$TIER"
  dest="$tier_dir/$STAMP"
  mkdir -p "$LOG_DIR" "$dest"

  info "=== Sauvegarde $TIER - $STAMP ==="
  say "Sauvegarde $TIER du $DAY sur $(hostname)"
  say ""
  say "Destination : $dest"
  say "Mode        : STOP_MODE=$STOP_MODE, image=$BACKUP_IMAGE, chiffrement=$ENCRYPT"
  say ""

  local c
  for c in $CONTAINERS; do
    backup_container "$c" "$dest" || true
  done

  # La sauvegarde ne doit surtout pas etre annoncee comme reussie si elle ne
  # l'est pas : c'etait le defaut central de la version precedente, ou le
  # `$? -eq 0` testait en realite le code retour de la fonction de log.
  if [ "$FAILURES" -gt 0 ]; then
    printf 'ECHEC\n' > "$dest/STATUS"
  else
    printf 'OK\n' > "$dest/STATUS"
  fi

  say ""
  rotate "$tier_dir" "$keep"
  offsite_sync || true

  local size status
  size="$(du -sh "$dest" 2>/dev/null | cut -f1)"
  say "Taille      : ${size:-?}"
  say "Echecs      : $FAILURES"

  if [ "$FAILURES" -gt 0 ]; then
    status="ECHEC"
    info "=== Termine avec $FAILURES echec(s) ==="
  else
    status="OK"
    info "=== Termine sans erreur ==="
  fi

  send_report "$status"
  [ "$FAILURES" -eq 0 ]
}

cmd_list() {
  local tier d
  for tier in daily weekly monthly; do
    [ -d "$BACKUP_ROOT/$tier" ] || continue
    printf '\n%s/\n' "$tier"
    for d in "$BACKUP_ROOT/$tier"/*/; do
      [ -d "$d" ] || continue
      printf '  %-28s %-8s %s\n' \
        "$(basename "$d")" \
        "$(cat "$d/STATUS" 2>/dev/null || echo '?')" \
        "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
  done
}

cmd_verify() {
  local dir="${1:-}" f bad=0 n=0
  [ -d "$dir" ] || die "repertoire introuvable : $dir"

  info "verification de $dir"
  while IFS= read -r f; do
    n=$((n + 1))
    if verify_archive "$f"; then
      info "  OK   $(basename "$f")"
    else
      err "  ILLISIBLE  $(basename "$f")"
      bad=$((bad + 1))
    fi
  done < <(find "$dir" -type f \( -name '*.tar.gz' -o -name '*.tar.gz.gpg' \))

  if [ -f "$dir/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
    if ( cd "$(dirname "$dir")" && sha256sum -c --quiet "$dir/SHA256SUMS" ); then
      info "  empreintes SHA256 conformes"
    else
      warn "  empreintes SHA256 non verifiables (archives chiffrees ou deplacees)"
    fi
  fi

  info "$n archive(s), $bad en echec"
  [ "$bad" -eq 0 ]
}

# Une sauvegarde jamais restauree n'est pas une sauvegarde : ce chemin doit
# exister et etre teste, pas seulement documente.
cmd_restore() {
  local dir="${1:-}" only="${2:-}"
  [ -d "$dir" ] || die "repertoire introuvable : $dir"

  if [ "${CONFIRM_RESTORE:-}" != "RESTORE" ]; then
    cat <<EOF

  RESTAURATION depuis : $dir

  Cette operation ECRASE le contenu actuel des volumes. Les conteneurs
  concernes seront arretes puis redemarres.

  Relancez avec :  CONFIRM_RESTORE=RESTORE $SCRIPT_NAME restore "$dir"

EOF
    exit 1
  fi

  require_tools
  acquire_lock

  # Une archive alteree ne doit jamais etre extraite. Si un attaquant obtient
  # l'ecriture sur le repertoire de sauvegarde, la restauration devient son
  # vecteur d'entree : on controle integrite et empreintes AVANT d'extraire.
  info "verification prealable des archives"
  cmd_verify "$dir" || die "verification echouee : restauration refusee"

  local container vol_dir archive src
  for vol_dir in "$dir"/volumes/*/; do
    [ -d "$vol_dir" ] || continue
    container="$(basename "$vol_dir")"
    [ -z "$only" ] || [ "$only" = "$container" ] || continue

    info "restauration de $container"
    docker inspect "$container" >/dev/null 2>&1 \
      || { err "  conteneur introuvable : $container"; continue; }

    docker stop "$container" >/dev/null 2>&1 && STOPPED_CONTAINER="$container"

    local i=0
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      [ -d "$src" ] || continue
      i=$((i + 1))
      archive="$(find "$vol_dir" -maxdepth 1 -name "${i}-*.tar.gz" | head -1)"
      if [ -z "$archive" ]; then
        warn "  aucune archive pour le volume $i ($src)"
        continue
      fi
      info "  $(basename "$archive") -> $src"
      tar -C "$src" -xzf "$archive" || err "  extraction echouee : $src"
    done < <(container_volumes "$container")

    thaw_container
    info "  $i volume(s) traite(s)"
  done

  [ "$FAILURES" -eq 0 ]
}

# =============================================================================
# Point d'entree
# =============================================================================
main() {
  local cmd="${1:-}"
  case "$cmd" in
    daily|weekly|monthly) cmd_backup "$cmd" ;;
    list)                 cmd_list ;;
    verify)               shift; cmd_verify "${1:-}" ;;
    restore)              shift; cmd_restore "${1:-}" "${2:-}" ;;
    -h|--help|help)       usage 0 ;;
    # Sans argument, on sort en ERREUR plutot qu'en affichant l'aide : une
    # crontab appelant « docker_backup.sh » tout court ne doit pas devenir
    # une tache silencieusement inoperante. Cron enverra la sortie d'erreur.
    '')                   printf 'Aucune commande. La crontab doit appeler : %s daily|weekly|monthly\n\n' \
                            "$SCRIPT_NAME" >&2
                          usage 1 ;;
    *)                    printf 'Commande inconnue : %s\n\n' "$cmd" >&2; usage 1 ;;
  esac
}

# Le garde permet de sourcer ce fichier pour tester ses fonctions (bats)
# sans declencher l'execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
