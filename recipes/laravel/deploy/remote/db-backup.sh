#!/usr/bin/env bash
# =============================================================================
# db-backup.sh - dump SQL compresse (prefixe db-manual-) dans backup/, hors
# cycle de deploiement.
#
# La validation du dump vit dans _lib.sh (db_backup) : gzip -t, marqueur
# "Dump completed" (un gzip de flux vide pese 20 octets et passait un simple
# `test -s`) et rotation KEEP_DUMPS propre au prefixe manuel.
#
# Concatene apres _lib.sh.
# =============================================================================

phase "db:backup"
db_backup manual
