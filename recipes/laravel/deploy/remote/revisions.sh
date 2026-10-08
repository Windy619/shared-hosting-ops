#!/usr/bin/env bash
# =============================================================================
# revisions.sh - affiche revisions.log (qui a deploye quoi, et quand).
#
# Capistrano : "used to log every deploy or rollback. Each entry is
# timestamped and the executing user is listed."
#
# Concatene apres _lib.sh.
# =============================================================================

LINES="${LINES:-20}"

phase "revisions.log"

if [ ! -s "$REVISIONS_LOG" ]; then
  log "aucune entree pour l'instant"
  exit 0
fi

printf '  %-20s  %-8s  %-22s  %-10s  %s\n' "DATE (UTC)" "ACTION" "RELEASE" "REVISION" "PAR"
tail -n "$LINES" "$REVISIONS_LOG" | sed 's/^/  /'

printf '\n'
if [ -L "$CURRENT_LINK" ]; then
  log "release active : $(basename "$(readlink -f "$CURRENT_LINK")")"
fi
