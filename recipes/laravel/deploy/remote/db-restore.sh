#!/usr/bin/env bash
# =============================================================================
# db-restore.sh - rejoue un dump de backup/ (DUMP, le plus recent par defaut).
#
# Chainon qui manquait : un dump jamais restaure n'est pas une sauvegarde.
# Operation DESTRUCTIVE, donc jamais automatique et jamais appelee par le
# deploiement ni par le rollback : verrou CONFIRM_RESTORE, et le site passe en
# maintenance pendant l'import.
#
# Concatene apres _lib.sh.
# =============================================================================

DUMP="${DUMP:-}"

phase "db:restore"

if [ "${CONFIRM_RESTORE:-}" != "RESTORE" ]; then
  die "restauration non confirmee.
  Cette operation ECRASE la base courante : tout ce qui a ete ecrit depuis le
  dump sera perdu (un dump de securite de l'etat actuel est pris avant).
  Relancez avec CONFIRM_RESTORE=RESTORE si c'est bien l'intention."
fi

dump_path="$(db_pick_dump "$DUMP")"
log "dump choisi : $(basename "$dump_path")"

maintenance_on
db_restore "$dump_path"
maintenance_off
ok "site remis en ligne"

log_revision "db-restore" "$(basename "$dump_path")"
