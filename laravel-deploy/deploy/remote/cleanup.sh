#!/usr/bin/env bash
# =============================================================================
# cleanup.sh - elagage des releases (`deploy:cleanup`).
#
# Conserve les KEEP_RELEASES plus recentes. La release pointee par current
# est protegee quoi qu'il arrive. Les dumps SQL de backup/ ont leur propre
# rotation dans db_backup : une seule regle par type d'objet, jamais deux
# rotations concurrentes sur le meme repertoire.
#
# Concatene apres _lib.sh.
# =============================================================================

phase "deploy:cleanup"
cleanup_releases

n=0
for d in "$RELEASES_DIR"/*/; do
  [ -d "$d" ] && n=$((n + 1))
done
log "releases conservees : $n (KEEP_RELEASES=$KEEP_RELEASES)"
