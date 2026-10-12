#!/usr/bin/env bats
#
# deploy/remote/_lib.sh - dumps SQL : nommage, rotation par prefixe, choix du
# fichier, verification avant restauration.
#
# mysqldump et mysql sont des faux : on verifie ce qui AURAIT ete envoye au
# serveur SQL, jamais son effet.

load helpers

setup() {
  TMP="$(make_tmpdir)"
  export PROJECT_DIR="$TMP/app"
  export KEEP_DUMPS=10
  export MYSQL_LOG="$TMP/mysql.log"
  mkdir -p "$PROJECT_DIR/shared" "$PROJECT_DIR/backup" "$TMP/bin"
  printf 'DB_DATABASE=app\nDB_USERNAME=u\nDB_PASSWORD=p\n' > "$PROJECT_DIR/shared/.env"
  : > "$MYSQL_LOG"

  {
    echo '#!/usr/bin/env bash'
    echo 'echo "INSERT fake-row;"'
    echo '[ "${FAKE_INCOMPLETE:-0}" = "1" ] || echo "-- Dump completed on 2026-01-01"'
    echo 'exit "${FAKE_DUMP_RC:-0}"'
  } > "$TMP/bin/mysqldump"
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$*" in *" -e "*) echo "DROP TABLE IF EXISTS \`orphan\`;"; exit 0 ;; esac'
    echo 'cat >> "$MYSQL_LOG"'
  } > "$TMP/bin/mysql"
  chmod +x "$TMP/bin/mysqldump" "$TMP/bin/mysql"
  PATH="$TMP/bin:$PATH"

  # shellcheck source=/dev/null
  source "$(repo_root)/recipes/laravel/deploy/remote/_lib.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  return 0
}

# Cree un dump valide de contenu quelconque, daté de $3 (touch -d).
mk_dump() {
  printf '%s\n-- Dump completed on x\n' "$2" | gzip > "$DB_BACKUP_DIR/$1"
  touch -d "$3" "$DB_BACKUP_DIR/$1"
}

# --- db_backup ---------------------------------------------------------------

@test "db_backup : DB_DATABASE absent, echec et non saut silencieux" {
  : > "$PROJECT_DIR/shared/.env"
  run db_backup pre 20260101000000
  [ "$status" -ne 0 ]
  [[ "$output" == *"DB_DATABASE"* ]]
}

@test "db_backup : client introuvable, echec" {
  run db_load_conf client-sql-inexistant
  [ "$status" -ne 0 ]
  [[ "$output" == *"introuvable"* ]]
}

@test "db_backup pre : nomme le dump d'apres la release, en mode 600" {
  # Git Bash sous Windows ignore chmod : le mode n'y est pas verifiable.
  : > "$TMP/probe"; chmod 600 "$TMP/probe"
  [ "$(stat -c %a "$TMP/probe")" = "600" ] || skip "chmod sans effet sur cette plateforme"

  db_backup pre 20260101000000
  f="$DB_BACKUP_DIR/db-pre-20260101000000.sql.gz"
  [ -f "$f" ]
  [ "$LAST_DUMP" = "db-pre-20260101000000.sql.gz" ]
  [ "$(stat -c %a "$f")" = "600" ]
}

@test "db_backup : un dump sans marqueur est refuse et supprime" {
  export FAKE_INCOMPLETE=1
  run db_backup manual 20260101000000
  [ "$status" -ne 0 ]
  [ ! -e "$DB_BACKUP_DIR/db-manual-20260101000000.sql.gz" ]
}

@test "db_backup : un echec de mysqldump est refuse et supprime" {
  export FAKE_DUMP_RC=2
  run db_backup manual 20260101000000
  [ "$status" -ne 0 ]
  [ ! -e "$DB_BACKUP_DIR/db-manual-20260101000000.sql.gz" ]
}

@test "db_backup : KEEP_DUMPS invalide est refuse avant tout dump" {
  export KEEP_DUMPS=0
  run db_backup manual 20260101000000
  [ "$status" -ne 0 ]
  [ -z "$(ls "$DB_BACKUP_DIR")" ]
}

# --- Rotation ----------------------------------------------------------------

@test "rotation : par prefixe, les dumps manuels n'evincent pas ceux d'avant migration" {
  export KEEP_DUMPS=2
  mk_dump db-pre-20260101000000.sql.gz a "2026-01-01"
  mk_dump db-pre-20260102000000.sql.gz a "2026-01-02"
  mk_dump db-pre-20260103000000.sql.gz a "2026-01-03"
  mk_dump db-manual-20260101000000.sql.gz a "2026-01-01"
  mk_dump db-manual-20260102000000.sql.gz a "2026-01-02"

  db_backup manual 20260110000000

  [ "$(ls "$DB_BACKUP_DIR" | grep -c '^db-pre-')" -eq 3 ]
  [ "$(ls "$DB_BACKUP_DIR" | grep -c '^db-manual-')" -eq 2 ]
  [ ! -e "$DB_BACKUP_DIR/db-manual-20260101000000.sql.gz" ]
}

@test "rotation : un dump de securite n'est jamais elague" {
  export KEEP_DUMPS=1
  mk_dump db-safety-20260101000000.sql.gz a "2026-01-01"
  mk_dump db-safety-20260102000000.sql.gz a "2026-01-02"

  db_backup safety 20260103000000

  [ "$(ls "$DB_BACKUP_DIR" | grep -c '^db-safety-')" -eq 3 ]
}

# --- Choix du dump -----------------------------------------------------------

@test "db_pick_dump : par defaut, le plus recent hors dump de securite" {
  mk_dump db-pre-20260101000000.sql.gz a "2026-01-01"
  mk_dump db-manual-20260102000000.sql.gz a "2026-01-02"
  mk_dump db-safety-20260103000000.sql.gz a "2026-01-03"

  run db_pick_dump ""
  [ "$status" -eq 0 ]
  [ "$output" = "$DB_BACKUP_DIR/db-manual-20260102000000.sql.gz" ]
}

@test "db_pick_dump : DUMP explicite, y compris un dump de securite" {
  mk_dump db-pre-20260101000000.sql.gz a "2026-01-01"
  mk_dump db-safety-20260103000000.sql.gz a "2026-01-03"

  run db_pick_dump db-pre-20260101000000.sql.gz
  [ "$output" = "$DB_BACKUP_DIR/db-pre-20260101000000.sql.gz" ]
  run db_pick_dump db-safety-20260103000000.sql.gz
  [ "$status" -eq 0 ]
}

@test "db_pick_dump : refuse un chemin, un mauvais nom et un fichier absent" {
  run db_pick_dump ../shared/.env
  [ "$status" -ne 0 ]
  run db_pick_dump /etc/passwd
  [ "$status" -ne 0 ]
  run db_pick_dump notes.txt
  [ "$status" -ne 0 ]
  run db_pick_dump db-pre-absent.sql.gz
  [ "$status" -ne 0 ]
}

@test "db_pick_dump : aucun dump, echec" {
  run db_pick_dump ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"aucun dump"* ]]
}

# --- Restauration ------------------------------------------------------------

@test "db_restore : une archive tronquee est refusee sans rien envoyer a mysql" {
  mk_dump db-pre-20260101000000.sql.gz "$(seq 1 2000)" "2026-01-01"
  head -c 40 "$DB_BACKUP_DIR/db-pre-20260101000000.sql.gz" > "$TMP/cut.gz"

  run db_restore "$TMP/cut.gz"
  [ "$status" -ne 0 ]
  [ ! -s "$MYSQL_LOG" ]
  [ -z "$(ls "$DB_BACKUP_DIR" | grep '^db-safety-')" ]
}

@test "db_restore : un dump sans marqueur est refuse sans rien envoyer a mysql" {
  printf 'INSERT x;\n' | gzip > "$TMP/nomark.gz"
  run db_restore "$TMP/nomark.gz"
  [ "$status" -ne 0 ]
  [ ! -s "$MYSQL_LOG" ]
}

@test "db_restore : dump de securite, puis vidage des tables, puis import" {
  mk_dump db-pre-20260101000000.sql.gz "INSERT restored-row;" "2026-01-01"

  run db_restore "$DB_BACKUP_DIR/db-pre-20260101000000.sql.gz"
  [ "$status" -eq 0 ]

  [ "$(ls "$DB_BACKUP_DIR" | grep -c '^db-safety-')" -eq 1 ]
  drop="$(grep -n 'orphan' "$MYSQL_LOG" | head -n 1 | cut -d: -f1)"
  import="$(grep -n 'restored-row' "$MYSQL_LOG" | head -n 1 | cut -d: -f1)"
  [ -n "$drop" ] && [ -n "$import" ]
  [ "$drop" -lt "$import" ]
}

# --- revisions.log et rollback -----------------------------------------------

@test "log_revision : le nom du dump d'avant migration est note" {
  export DEPLOYER="alice" REVISION="abc1234"
  : > "$REVISIONS_LOG"
  log_revision "deploy" "20260101000000" "db-pre-20260101000000.sql.gz"
  run cat "$REVISIONS_LOG"
  [[ "$output" == *"dump db-pre-20260101000000.sql.gz"* ]]
}

@test "rollback.sh : ne restaure plus la base" {
  run grep -E 'RESTORE_DB|db_restore' "$(repo_root)/recipes/laravel/deploy/remote/rollback.sh"
  [ "$status" -ne 0 ]
}
