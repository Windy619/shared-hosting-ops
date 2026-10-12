#!/usr/bin/env bash
# =============================================================================
# rollback.sh - retour a la release precedente (flow `deploy:reverting`).
#
# Les releases restent dans releases/ : le retour arriere se resume a
# repointer le symlink. Aucune copie, donc une bascule instantanee, et
# autant de niveaux de retour que de releases conservees.
#
# La BASE DE DONNEES n'est jamais restauree ici : rejouer un dump detruirait
# tout ce qui a ete ecrit depuis. Code et base se restaurent separement
# (db-restore.sh), chacun derriere son propre verrou.
#
# Concatene apres _lib.sh.
# =============================================================================

phase "deploy:reverting"

[ -L "$CURRENT_LINK" ] || die "aucune release active : rien a annuler"

current_name="$(basename "$(readlink -f "$CURRENT_LINK")")"
log "release active   : $current_name"

target="$(previous_release)" || die "aucune release precedente exploitable dans releases/
  (une release sans vendor/autoload.php est ignoree : elle serait inutilisable)"

log "release ciblee   : $(basename "$target")"

maintenance_on

log "base non restauree"
if [ -f "$DB_BACKUP_DIR/db-pre-$current_name.sql.gz" ]; then
  log "etat d'avant la release annulee : make db-restore DUMP=db-pre-$current_name.sql.gz"
fi

# =============================================================================
phase "deploy:reverted"
# =============================================================================
publish_release "$target"
ok "current -> $(basename "$target")"

cd "$CURRENT_LINK" || die "current inaccessible apres bascule"
"$PHP_BIN" artisan optimize:clear
"$PHP_BIN" artisan view:cache    || warn "view:cache ignore"
"$PHP_BIN" artisan queue:restart || warn "queue:restart ignore"
restart_workers

maintenance_off
ok "site remis en ligne"

# =============================================================================
phase "deploy:finishing_rollback"
# =============================================================================
# La release annulee reste dans releases/ : elle sera elaguee normalement par
# KEEP_RELEASES, et reste disponible pour un retour en avant immediat.
log_revision "rollback" "$(basename "$target")"

printf '\n  Rollback termine - release active : %s\n' "$(basename "$target")"
printf '  Release annulee conservee : %s\n' "$current_name"
