#!/usr/bin/env bash
# =============================================================================
# init.sh - prepare l'arborescence Capistrano sur le serveur.
#
# Idempotent : relancable sans risque, n'ecrase jamais un fichier existant.
# EXTRA_DIRS permet d'ajouter des repertoires propres a l'hebergeur
# (ex. "www" pour un docroot physique impose type AmenPanel).
#
# Concatene apres _lib.sh.
# =============================================================================

EXTRA_DIRS="${EXTRA_DIRS:-}"

phase "init"

mkdir -p "$RELEASES_DIR" "$DB_BACKUP_DIR" "$SHARED_DIR"
ok "releases/ backup/ shared/"

# Squelette storage de Laravel, partage entre toutes les releases.
mkdir -p \
  "$SHARED_DIR/storage/app/public" \
  "$SHARED_DIR/storage/app/private" \
  "$SHARED_DIR/storage/framework/cache/data" \
  "$SHARED_DIR/storage/framework/sessions" \
  "$SHARED_DIR/storage/framework/testing" \
  "$SHARED_DIR/storage/framework/views" \
  "$SHARED_DIR/storage/logs"

# Le X majuscule n'ajoute le bit d'execution que sur les DOSSIERS : un
# chmod -R 775 rendait aussi executables logs, vues compilees et sessions.
chmod -R u=rwX,g=rwX,o= "$SHARED_DIR/storage"
ok "shared/storage/ (dossiers 770, fichiers 660)"

for d in $EXTRA_DIRS; do
  mkdir -p "$PROJECT_DIR/$d"
  ok "$d/"
done

touch "$REVISIONS_LOG"
ok "revisions.log"

if [ -f "$SHARED_DIR/.env" ]; then
  chmod 600 "$SHARED_DIR/.env"
  ok "shared/.env present (600)"
else
  warn "shared/.env ABSENT - deposez-le avant tout deploiement."
  warn "  Il doit contenir au minimum APP_KEY, DB_* et APP_URL."
fi

printf '\n  Arborescence prete dans %s\n' "$PROJECT_DIR"
