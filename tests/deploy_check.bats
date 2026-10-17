#!/usr/bin/env bats
#
# deploy/remote/_lib.sh - controles de deploy:check et premier deploiement :
# current qui n'est pas un lien, extension PDO du driver, dump d'avant
# migration sans release active.

load helpers

setup() {
  TMP="$(make_tmpdir)"
  export PROJECT_DIR="$TMP/app"
  export KEEP_DUMPS=10
  mkdir -p "$PROJECT_DIR/shared" "$PROJECT_DIR/backup" "$PROJECT_DIR/releases" "$TMP/bin"
  : > "$PROJECT_DIR/shared/.env"

  # Faux php : extension_loaded(...) reussit seulement pour l'extension de FAKE_EXT.
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$*" in *"extension_loaded('"'"'$FAKE_EXT'"'"')"*) exit 0 ;; esac'
    echo 'exit 1'
  } > "$TMP/bin/php"
  chmod +x "$TMP/bin/php"
  export PHP_BIN="$TMP/bin/php"

  # shellcheck source=/dev/null
  source "$(repo_root)/recipes/laravel/deploy/remote/_lib.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  return 0
}

# --- current ------------------------------------------------------------------

@test "check_current_link : un current qui est un dossier est refuse, avec la marche a suivre" {
  mkdir "$CURRENT_LINK"
  run check_current_link
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas un lien"* ]]
  [[ "$output" == *"mv current current.old"* ]]
}

@test "check_current_link : un current absent est accepte (premier deploiement)" {
  run check_current_link
  [ "$status" -eq 0 ]
}

@test "check_current_link : un vrai lien est accepte" {
  require_symlinks
  mkdir "$RELEASES_DIR/r1"
  ln -s "$RELEASES_DIR/r1" "$CURRENT_LINK"
  run check_current_link
  [ "$status" -eq 0 ]
}

# --- extension PDO -------------------------------------------------------------

@test "pdo_extension : le nom se deduit de DB_CONNECTION" {
  [ "$(pdo_extension mysql)" = "pdo_mysql" ]
  [ "$(pdo_extension mariadb)" = "pdo_mysql" ]
  [ "$(pdo_extension pgsql)" = "pdo_pgsql" ]
  [ "$(pdo_extension sqlite)" = "pdo_sqlite" ]
  [ -z "$(pdo_extension sqlsrv)" ]
}

@test "check_pdo_extension : pdo_pgsql absente, echec avant tout transfert" {
  echo 'DB_CONNECTION=pgsql' > "$SHARED_DIR/.env"
  export FAKE_EXT=pdo_mysql
  run check_pdo_extension
  [ "$status" -ne 0 ]
  [[ "$output" == *"pdo_pgsql"* ]]
}

@test "check_pdo_extension : extension presente, accepte" {
  echo 'DB_CONNECTION=pgsql' > "$SHARED_DIR/.env"
  export FAKE_EXT=pdo_pgsql
  run check_pdo_extension
  [ "$status" -eq 0 ]
}

@test "check_pdo_extension : driver inconnu ou absent, signale sans bloquer" {
  export FAKE_EXT=aucune
  echo 'DB_CONNECTION=sqlsrv' > "$SHARED_DIR/.env"
  run check_pdo_extension
  [ "$status" -eq 0 ]
  : > "$SHARED_DIR/.env"
  run check_pdo_extension
  [ "$status" -eq 0 ]
}

# --- premier deploiement -------------------------------------------------------

@test "db_backup_before_migration : sans current, le dump est saute et le dit" {
  echo 'DB_DATABASE=app' > "$SHARED_DIR/.env"
  run db_backup_before_migration 20260101000000
  [ "$status" -eq 0 ]
  [[ "$output" == *"premier deploiement"* ]]
  [ -z "$(ls "$DB_BACKUP_DIR")" ]
}

@test "db_backup_before_migration : DB_BACKUP=0, rien n'est tente" {
  export DB_BACKUP=0
  run db_backup_before_migration 20260101000000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "db_backup_before_migration : avec current, un dump impossible echoue" {
  require_symlinks
  mkdir "$RELEASES_DIR/r1"
  ln -s "$RELEASES_DIR/r1" "$CURRENT_LINK"
  : > "$SHARED_DIR/.env"
  run db_backup_before_migration 20260101000000
  [ "$status" -ne 0 ]
  [[ "$output" == *"DB_DATABASE"* ]]
}
