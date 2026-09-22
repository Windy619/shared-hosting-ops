#!/usr/bin/env bash
# =============================================================================
# db-backup.sh - dump SQL compresse dans backup/, hors cycle de deploiement.
#
# La validation du dump vit dans _lib.sh (db_backup) : identifiants lus dans
# shared/.env, MYSQL_PWD plutot que -p..., pipefail, et verification du
# marqueur "Dump completed" - un gzip de flux vide pese 20 octets et passait
# sans broncher un simple `test -s`.
#
# Concatene apres _lib.sh.
# =============================================================================

phase "db:backup"
db_backup
