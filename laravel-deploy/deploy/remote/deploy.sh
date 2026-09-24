#!/usr/bin/env bash
# =============================================================================
# deploy.sh - deploiement d'une release, selon le flow Capistrano.
#   https://capistranorb.com/documentation/getting-started/flow/
#
#   deploy:updating    extraction + liens shared/
#   deploy:updated     composer install          <- tout ce qui est long
#   deploy:publishing  maintenance, migrations, BASCULE de current
#   deploy:finishing   caches, queue, elagage, revisions.log
#
# Point essentiel : la bascule de `current` arrive A LA FIN. Tant qu'elle n'a
# pas eu lieu, un echec a n'importe quelle etape laisse le site intact sur
# l'ancienne release - c'est la garantie meme du modele :
#   "If the deployment fails in any step the current symlink still points to
#    the old release."
#
# Concatene apres _lib.sh.
# =============================================================================

: "${RELEASE_NAME:?RELEASE_NAME est requis}"
: "${ARCHIVE:?ARCHIVE est requis}"

MIGRATE_CMD="${MIGRATE_CMD:-}"
COMPOSER_FLAGS="${COMPOSER_FLAGS:---no-dev}"
ENABLE_CONFIG_CACHE="${ENABLE_CONFIG_CACHE:-0}"
DB_BACKUP="${DB_BACKUP:-1}"

# RELEASES_DIR, CURRENT_LINK, PHP_BIN... sont definis par _lib.sh, concatene
# devant ce fichier : shellcheck ne peut pas les voir en analyse isolee.
# shellcheck disable=SC2153
RELEASE_DIR="$RELEASES_DIR/$RELEASE_NAME"
SUCCESS=0

# --- Filet de securite -------------------------------------------------------
# Si le script s'interrompt avant la bascule, on efface la release partielle :
# elle ne doit ni encombrer releases/, ni devenir une cible de rollback.
on_exit() {
  [ "$SUCCESS" -eq 1 ] && return 0
  warn "deploiement interrompu"
  if [ -d "$RELEASE_DIR" ] \
     && [ "$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)" != "$(readlink -f "$RELEASE_DIR")" ]; then
    rm -rf "$RELEASE_DIR"
    warn "release $RELEASE_NAME incomplete supprimee - current inchange"
  fi
}
trap on_exit EXIT

# =============================================================================
phase "deploy:updating"
# =============================================================================
mkdir -p "$RELEASE_DIR"
tar -xzf "$RELEASES_DIR/$ARCHIVE" -C "$RELEASE_DIR"
rm -f "$RELEASES_DIR/$ARCHIVE"
ok "archive extraite dans releases/$RELEASE_NAME"

link_shared "$RELEASE_DIR"

# =============================================================================
phase "deploy:updated"
# =============================================================================
cd "$RELEASE_DIR" || die "release introuvable : $RELEASE_DIR"

# COMPOSER_FLAGS contient plusieurs options : la separation en mots est voulue.
# shellcheck disable=SC2086
"$PHP_BIN" "$COMPOSER_BIN" install $COMPOSER_FLAGS \
  --optimize-autoloader --no-interaction --no-progress
ok "dependances PHP installees"

if [ "$DB_BACKUP" = "1" ]; then
  phase "sauvegarde de la base (avant migrations)"
  db_backup
fi

# =============================================================================
phase "deploy:publishing"
# =============================================================================
# A partir d'ici seulement le site est indisponible : bascule + migrations.
# Tout ce qui est long est deja fait.
maintenance_on

if [ -n "$MIGRATE_CMD" ]; then
  # --force est OBLIGATOIRE : sans lui, Laravel demande une confirmation
  # interactive des que APP_ENV=production, et abandonne faute de TTY.
  log "migrations : artisan $MIGRATE_CMD --force"
  # shellcheck disable=SC2086
  "$PHP_BIN" artisan $MIGRATE_CMD --force
  ok "migrations appliquees"
else
  log "migrations ignorees (MIGRATE_CMD vide)"
fi

publish_release "$RELEASE_DIR"
ok "current -> releases/$RELEASE_NAME"

# =============================================================================
phase "deploy:finishing"
# =============================================================================
cd "$CURRENT_LINK" || die "current inaccessible apres bascule"

"$PHP_BIN" artisan optimize:clear

# view:cache est sans risque. En revanche config:cache casse l'application si
# env() est appele ailleurs que dans config/, et route:cache echoue s'il
# existe une route en closure : desactives par defaut, a activer en
# connaissance de cause via ENABLE_CONFIG_CACHE=1.
"$PHP_BIN" artisan view:cache || warn "view:cache ignore"

if [ "$ENABLE_CONFIG_CACHE" = "1" ]; then
  "$PHP_BIN" artisan config:cache || warn "config:cache impossible (env() hors config/ ?)"
  "$PHP_BIN" artisan route:cache  || warn "route:cache impossible (route en closure ?)"
  ok "caches config + routes generes"
else
  log "config:cache / route:cache desactives (ENABLE_CONFIG_CACHE=1 pour les activer)"
fi

# Les deux sont complementaires : queue:restart demande aux workers de finir
# leur job en cours, restart_workers garantit qu'ils repartent sur le nouveau
# code au lieu de dependre de la politique autorestart de Supervisor.
"$PHP_BIN" artisan queue:restart || warn "queue:restart ignore"
restart_workers

maintenance_off
ok "site remis en ligne"

cleanup_releases
log_revision "deploy" "$RELEASE_NAME"

SUCCESS=1
printf '\n  Deploiement termine : %s\n' "$RELEASE_NAME"
