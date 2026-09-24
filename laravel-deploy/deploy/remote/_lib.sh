#!/usr/bin/env bash
# =============================================================================
# _lib.sh - fonctions communes executees SUR LE SERVEUR.
#
# Ce fichier n'est jamais lance seul : il est concatene devant check.sh,
# deploy.sh ou rollback.sh, et l'ensemble part sur le serveur par stdin :
#
#   cat deploy/remote/_lib.sh deploy/remote/deploy.sh \
#     | ssh hote "PROJECT_DIR='...' RELEASE_NAME='...' bash -s"
#
# Les parametres arrivent donc par variables d'environnement, jamais par
# interpolation de chaine : plus d'echappement imbrique (\$(...) dans "..."),
# et le code reste lisible et analysable par shellcheck.
#
# Structure cible : https://capistranorb.com/documentation/getting-started/structure/
# =============================================================================

set -euo pipefail

# --- Parametres attendus -----------------------------------------------------
: "${PROJECT_DIR:?PROJECT_DIR est requis}"
PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
DEPLOYER="${DEPLOYER:-inconnu}"
REVISION="${REVISION:-inconnue}"

# Le CI passe un chemin relatif au home ("public_html/app.example.com").
# On le rend absolu : les cibles de symlink doivent l'etre.
case "$PROJECT_DIR" in
  /*) ;;
   *) PROJECT_DIR="$HOME/$PROJECT_DIR" ;;
esac

# --- Structure Capistrano ----------------------------------------------------
RELEASES_DIR="$PROJECT_DIR/releases"
SHARED_DIR="$PROJECT_DIR/shared"
CURRENT_LINK="$PROJECT_DIR/current"
REVISIONS_LOG="$PROJECT_DIR/revisions.log"
DB_BACKUP_DIR="$PROJECT_DIR/backup"   # dumps SQL uniquement (plus de releases ici)

# --- linked_files / linked_dirs ----------------------------------------------
# Format "chemin_dans_shared:chemin_dans_la_release", un par ligne.
#
# Ecart assume vs Capistrano : shared/ est plat (heritage des serveurs deja
# en place) au lieu de refleter l'arborescence de la release. Le mapping
# explicite ci-dessous rend la correspondance lisible et modifiable sans
# toucher au code.
LINKED_FILES_MAP="${LINKED_FILES_MAP:-.env:.env
.htaccess:public/.htaccess
php.ini:public/php.ini
.user.ini:public/.user.ini}"

LINKED_DIRS_MAP="${LINKED_DIRS_MAP:-storage:storage}"

# --- Sorties -----------------------------------------------------------------
log()   { printf '  %s\n' "$*"; }
ok()    { printf '  + %s\n' "$*"; }
warn()  { printf '  ! %s\n' "$*" >&2; }
die()   { printf '\nERREUR : %s\n' "$*" >&2; exit 1; }
phase() { printf '\n--- %s ---\n' "$*"; }

# --- Lecture du .env partage -------------------------------------------------
env_get() {
  [ -f "$SHARED_DIR/.env" ] || return 1
  sed -n "s/^[[:space:]]*$1=//p" "$SHARED_DIR/.env" | head -n 1 | tr -d '\r"'
}

# --- Liens vers shared/ ------------------------------------------------------
link_shared() {
  local release="$1" src dest

  while IFS=: read -r src dest; do
    [ -n "${src:-}" ] || continue
    [ -f "$SHARED_DIR/$src" ] || die "linked_file absent : shared/$src"
    mkdir -p "$(dirname "$release/$dest")"
    ln -sfn "$SHARED_DIR/$src" "$release/$dest"
    ok "$dest -> shared/$src"
  done <<< "$LINKED_FILES_MAP"

  while IFS=: read -r src dest; do
    [ -n "${src:-}" ] || continue
    [ -d "$SHARED_DIR/$src" ] || die "linked_dir absent : shared/$src"
    rm -rf "${release:?}/${dest:?}"
    mkdir -p "$(dirname "$release/$dest")"
    ln -sfn "$SHARED_DIR/$src" "$release/$dest"
    ok "$dest/ -> shared/$src/"
  done <<< "$LINKED_DIRS_MAP"
}

# --- Bascule de current ------------------------------------------------------
# Capistrano : "This symlink is updated at the end of a successful deployment."
# On passe par un lien temporaire + rename(2), qui est atomique : a aucun
# instant current ne pointe dans le vide.
publish_release() {
  local target="$1"
  ln -sfn "$target" "$CURRENT_LINK.tmp"
  if mv -Tf "$CURRENT_LINK.tmp" "$CURRENT_LINK" 2>/dev/null; then
    return 0
  fi
  # mv -T absent (non GNU) : repli en deux temps, fenetre reduite au minimum.
  rm -f "$CURRENT_LINK.tmp"
  ln -sfn "$target" "$CURRENT_LINK"
}

# --- Release precedente exploitable (pour le rollback) -----------------------
previous_release() {
  local cur d dirs=()
  cur="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"

  for d in "$RELEASES_DIR"/*/; do
    [ -d "$d" ] || continue
    dirs+=("${d%/}")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 1

  # Noms horodates AAAAMMJJHHMMSS : le tri lexicographique inverse est
  # exactement le tri chronologique decroissant.
  mapfile -t dirs < <(printf '%s\n' "${dirs[@]}" | sort -r)

  for d in "${dirs[@]}"; do
    [ "$(readlink -f "$d")" = "$cur" ] && continue
    [ -f "$d/vendor/autoload.php" ] || continue   # release incomplete : inutilisable
    printf '%s\n' "$d"
    return 0
  done
  return 1
}

# --- Elagage : on garde les KEEP_RELEASES plus recentes ----------------------
cleanup_releases() {
  local cur d dirs=() i=0
  cur="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"

  for d in "$RELEASES_DIR"/*/; do
    [ -d "$d" ] || continue
    dirs+=("${d%/}")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0

  mapfile -t dirs < <(printf '%s\n' "${dirs[@]}" | sort -r)

  for d in "${dirs[@]}"; do
    i=$((i + 1))
    [ "$i" -le "$KEEP_RELEASES" ] && continue
    if [ "$(readlink -f "$d")" = "$cur" ]; then
      log "= $(basename "$d") (active, conservee)"
      continue
    fi
    rm -rf "$d" && ok "- $(basename "$d") supprimee"
  done
}

# --- revisions.log -----------------------------------------------------------
# Capistrano : "used to log every deploy or rollback. Each entry is timestamped
# and the executing user is listed."
log_revision() {
  local action="$1" release="$2" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s  %-8s  %s  %s  by %s\n' \
    "$ts" "$action" "$release" "$REVISION" "$DEPLOYER" >> "$REVISIONS_LOG"
  ok "revisions.log mis a jour"
}

# --- Mode maintenance --------------------------------------------------------
maintenance_on() {
  if [ ! -L "$CURRENT_LINK" ]; then
    log "aucune release active : maintenance inutile (premier deploiement)"
    return 0
  fi
  # storage/ etant partage, l'etat de maintenance survit a la bascule.
  ( cd "$CURRENT_LINK" && "$PHP_BIN" artisan down --retry=30 ) \
    || warn "artisan down a echoue (ignore)"
}

maintenance_off() {
  ( cd "$CURRENT_LINK" && "$PHP_BIN" artisan up ) \
    || die "artisan up a echoue : le site reste en maintenance, intervention requise"
}

# --- Workers -----------------------------------------------------------------
# `artisan queue:restart` est un signal cooperatif : le worker sort en 0 en fin
# de job, et une config Supervisor en `autorestart=unexpected` considere cette
# sortie comme attendue, donc ne le relance jamais. Reverb, lui, n'ecoute meme
# pas ce signal. D'ou ce redemarrage explicite, par groupe Supervisor.
#
# SUPERVISOR_GROUPS vide : le helper ne fait rien. Un serveur sans worker ne
# doit pas voir son deploiement changer de comportement.
restart_workers() {
  [ -n "${SUPERVISOR_GROUPS:-}" ] || return 0

  if ! command -v supervisorctl >/dev/null 2>&1; then
    log "supervisorctl absent : ce serveur n'heberge aucun worker"
    return 0
  fi

  # Les groupes demandes sont des candidats, pas une verite : un projet peut
  # n'avoir ni worker ni reverb. On confronte la liste a l'etat reel plutot que
  # d'alerter sur des groupes qui n'ont jamais existe. Une ligne de `status`
  # vaut "groupe:programme_00   RUNNING   pid ...", d'ou la coupe au ':'.
  local declared
  declared="$(sudo supervisorctl status 2>/dev/null | awk -F'[: ]' '{print $1}' | sort -u || true)"
  if [ -z "$declared" ]; then
    warn "supervisor : etat illisible (sudo ou socket), aucun groupe relance"
    return 0
  fi

  local group
  # shellcheck disable=SC2086  # SUPERVISOR_GROUPS liste plusieurs groupes
  for group in $SUPERVISOR_GROUPS; do
    if ! printf '%s' "$declared" | grep -qxF "$group"; then
      log "supervisor : $group non declare, ignore"
      continue
    fi
    if sudo supervisorctl restart "$group:*" >/dev/null 2>&1; then
      ok "supervisor : $group relance"
    else
      warn "supervisor : echec de  sudo supervisorctl restart $group:*"
    fi
  done
}

# --- Sauvegarde SQL ----------------------------------------------------------
db_backup() {
  local name user host port pass f

  name="$(env_get DB_DATABASE || true)"
  if [ -z "${name:-}" ]; then
    warn "DB_DATABASE absent de shared/.env : dump ignore"
    return 0
  fi
  if ! command -v mysqldump >/dev/null 2>&1; then
    warn "mysqldump introuvable sur le serveur : dump ignore"
    return 0
  fi

  user="$(env_get DB_USERNAME || true)"
  host="$(env_get DB_HOST || true)"
  port="$(env_get DB_PORT || true)"
  pass="$(env_get DB_PASSWORD || true)"

  mkdir -p "$DB_BACKUP_DIR"
  f="$DB_BACKUP_DIR/db-$(date -u +%Y%m%d%H%M%S).sql.gz"

  # Le dump est restreint AVANT d'etre rempli. Un chmod applique apres coup
  # laissait le fichier lisible par tous pendant toute la duree du mysqldump,
  # soit plusieurs minutes sur une base volumineuse.
  : > "$f"
  chmod 600 "$f"

  # MYSQL_PWD plutot que -p... : le mot de passe n'apparait pas dans ps.
  # pipefail (actif via set -o pipefail) fait remonter l'echec de mysqldump
  # meme si gzip, lui, reussit.
  MYSQL_PWD="$pass" mysqldump \
      --no-tablespaces --single-transaction --quick --routines --events \
      --default-character-set=utf8mb4 \
      -h "${host:-127.0.0.1}" -P "${port:-3306}" -u "$user" "$name" \
    | gzip -9 > "$f" \
    || { rm -f "$f"; die "mysqldump a echoue"; }

  # Un gzip de flux vide pese ~20 octets : "test -s" ne prouve donc RIEN.
  # Seul le marqueur de fin de mysqldump atteste d'un dump complet.
  if ! gunzip -c "$f" | tail -n 5 | grep -q 'Dump completed'; then
    rm -f "$f"
    die "dump incomplet : marqueur 'Dump completed' absent"
  fi

  chmod 600 "$f"
  ok "dump : $(basename "$f") ($(du -h "$f" | cut -f1))"

  # Rotation : 10 dumps conserves.
  # shellcheck disable=SC2012  # noms horodates, sans espace : ls est sur ici
  ls -1t "$DB_BACKUP_DIR"/db-*.sql.gz 2>/dev/null | tail -n +11 | while read -r f; do
    rm -f "$f"
  done
}

# --- Restauration SQL (destructive, jamais automatique) ----------------------
db_restore_latest() {
  local name user host port pass f

  # shellcheck disable=SC2012  # noms horodates generes ici, sans espace
  f="$(ls -1t "$DB_BACKUP_DIR"/db-*.sql.gz 2>/dev/null | head -n 1 || true)"
  [ -n "${f:-}" ] || die "aucun dump disponible dans backup/"

  name="$(env_get DB_DATABASE || true)"
  [ -n "${name:-}" ] || die "DB_DATABASE absent de shared/.env"
  command -v mysql >/dev/null 2>&1 || die "client mysql introuvable"

  user="$(env_get DB_USERNAME || true)"
  host="$(env_get DB_HOST || true)"
  port="$(env_get DB_PORT || true)"
  pass="$(env_get DB_PASSWORD || true)"

  warn "RESTAURATION de $(basename "$f") dans la base $name"
  warn "Toute donnee ecrite depuis ce dump sera PERDUE."

  gunzip -c "$f" \
    | MYSQL_PWD="$pass" mysql -h "${host:-127.0.0.1}" -P "${port:-3306}" -u "$user" "$name" \
    || die "restauration echouee"

  ok "base restauree depuis $(basename "$f")"
}
