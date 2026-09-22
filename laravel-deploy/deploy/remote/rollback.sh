#!/usr/bin/env bash
# =============================================================================
# rollback.sh - retour a la release precedente (flow `deploy:reverting`).
#
# Les releases restent dans releases/ : le retour arriere se resume a
# repointer le symlink. Aucune copie, donc une bascule instantanee, et
# autant de niveaux de retour que de releases conservees.
#
# La BASE DE DONNEES n'est jamais restauree automatiquement : rejouer un dump
# detruirait tout ce qui a ete ecrit depuis. Si la release fautive portait une
# migration destructrice, relancer avec RESTORE_DB=1 - en connaissance de cause.
#
# Concatene apres _lib.sh.
# =============================================================================

RESTORE_DB="${RESTORE_DB:-0}"

phase "deploy:reverting"

[ -L "$CURRENT_LINK" ] || die "aucune release active : rien a annuler"

current_name="$(basename "$(readlink -f "$CURRENT_LINK")")"
log "release active   : $current_name"

target="$(previous_release)" || die "aucune release precedente exploitable dans releases/
  (une release sans vendor/autoload.php est ignoree : elle serait inutilisable)"

log "release ciblee   : $(basename "$target")"

maintenance_on

if [ "$RESTORE_DB" = "1" ]; then
  phase "restauration de la base"
  db_restore_latest
else
  log "base non restauree (RESTORE_DB=1 pour la rejouer depuis le dernier dump)"
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
