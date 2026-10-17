#!/usr/bin/env bash
# =============================================================================
# check.sh - equivalent de `deploy:check` (Capistrano).
#
# Valide l'environnement AVANT que quoi que ce soit ne soit transfere.
# Capistrano refuse de deployer si un linked_file declare est absent ; sans
# ce controle, `ln -s` vers une cible inexistante REUSSIT et cree un lien
# mort, silencieusement (c'est ainsi que shared/.user.ini a pu manquer sur
# les serveurs sans que rien ne le signale).
#
# Concatene apres _lib.sh. Ne modifie rien, sauf les permissions du .env.
# =============================================================================

phase "deploy:check"

[ -d "$PROJECT_DIR" ] || die "repertoire projet absent : $PROJECT_DIR"
[ -d "$SHARED_DIR" ]  || die "shared/ absent : lancez d'abord init_server.sh sur ce serveur"

mkdir -p "$RELEASES_DIR"
touch "$REVISIONS_LOG"

missing=0

check_current_link

# --- linked_files ------------------------------------------------------------
while IFS=: read -r src dest; do
  [ -n "${src:-}" ] || continue
  if [ -f "$SHARED_DIR/$src" ]; then
    ok "linked_file  shared/$src  ->  $dest"
  else
    warn "linked_file MANQUANT : shared/$src  (attendu en $dest)"
    missing=$((missing + 1))
  fi
done <<< "$LINKED_FILES_MAP"

# --- linked_dirs -------------------------------------------------------------
while IFS=: read -r src dest; do
  [ -n "${src:-}" ] || continue
  if [ -d "$SHARED_DIR/$src" ]; then
    ok "linked_dir   shared/$src/  ->  $dest/"
  else
    warn "linked_dir MANQUANT : shared/$src/  (attendu en $dest/)"
    missing=$((missing + 1))
  fi
done <<< "$LINKED_DIRS_MAP"

if [ "$missing" -ne 0 ]; then
  die "$missing element(s) manquant(s) dans shared/ - deploiement refuse.
  Creez-les (init_server.sh), ou retirez-les de LINKED_FILES_MAP / LINKED_DIRS_MAP."
fi

# --- .env exploitable --------------------------------------------------------
app_key="$(env_get APP_KEY || true)"
if [ -z "${app_key:-}" ]; then
  die "APP_KEY vide dans shared/.env - Laravel leverait une erreur a chaque requete.
  Generez-la :  php artisan key:generate --show   puis reportez-la dans shared/.env"
fi
ok "APP_KEY presente"

app_env="$(env_get APP_ENV || true)"
log "APP_ENV = ${app_env:-non defini}"

# Le .env porte DB_PASSWORD, MAIL_PASSWORD et APP_KEY : il ne doit jamais
# etre lisible par les autres comptes de la machine (hebergement mutualise).
if perms="$(stat -c '%a' "$SHARED_DIR/.env" 2>/dev/null)"; then
  case "$perms" in
    600|400) ok ".env en $perms" ;;
    *)       chmod 600 "$SHARED_DIR/.env" && warn ".env etait en $perms - corrige en 600" ;;
  esac
fi

# --- Outils serveur ----------------------------------------------------------
if [ -x "$PHP_BIN" ] || command -v "$PHP_BIN" >/dev/null 2>&1; then
  ok "PHP : $("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || echo '?')"
else
  die "PHP introuvable : $PHP_BIN"
fi

[ -f "$COMPOSER_BIN" ] || command -v "$COMPOSER_BIN" >/dev/null 2>&1 \
  || die "composer introuvable : $COMPOSER_BIN"
ok "composer : $COMPOSER_BIN"

check_pdo_extension

# --- storage inscriptible ----------------------------------------------------
if [ -w "$SHARED_DIR/storage" ]; then
  ok "shared/storage/ inscriptible"
else
  die "shared/storage/ non inscriptible par $(id -un)"
fi

# --- Espace disque -----------------------------------------------------------
if avail="$(df -Pk "$PROJECT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"; then
  avail_mb=$((avail / 1024))
  if [ "$avail_mb" -lt 500 ]; then
    warn "espace disque faible : ${avail_mb} Mo restants"
  else
    ok "espace disque : ${avail_mb} Mo"
  fi
fi

# --- Etat courant ------------------------------------------------------------
if [ -L "$CURRENT_LINK" ]; then
  log "current -> $(basename "$(readlink -f "$CURRENT_LINK")")"
else
  log "current absent : ce sera le premier deploiement"
fi

n_releases=0
for d in "$RELEASES_DIR"/*/; do
  [ -d "$d" ] && n_releases=$((n_releases + 1))
done
log "releases presentes : $n_releases (KEEP_RELEASES=$KEEP_RELEASES)"

printf '\n  deploy:check OK\n'
