#!/usr/bin/env bash
# =============================================================================
# db-restore.sh - rejoue le dump le plus recent de backup/.
#
# Chainon qui manquait : un dump jamais restaure n'est pas une sauvegarde.
# Operation DESTRUCTIVE, donc jamais automatique et jamais appelee par le
# deploiement : double verrou (cible make dediee + CONFIRM_RESTORE).
#
# Concatene apres _lib.sh.
# =============================================================================

phase "db:restore"

if [ "${CONFIRM_RESTORE:-}" != "RESTORE" ]; then
  die "restauration non confirmee.
  Cette operation ECRASE la base courante avec le dernier dump : tout ce qui
  a ete ecrit depuis sera perdu.
  Relancez avec CONFIRM_RESTORE=RESTORE si c'est bien l'intention."
fi

db_restore_latest
