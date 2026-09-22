#!/usr/bin/env bats
#
# aide.sh - interpretation du code de sortie d'AIDE, integrite de la base,
#           rotation des rapports.
#
# Le code de sortie est la source de verite du verdict. La version d'origine
# cherchait la chaine "AIDE found differences" dans la sortie et ne savait donc
# pas distinguer « aucune difference » d'« AIDE a echoue » : les deux
# produisaient le meme courriel rassurant.

load helpers

setup() {
  TMP="$(make_tmpdir)"
  export AIDE_DB="$TMP/aide.db.gz"
  export REPORT_DIR="$TMP/reports"
  export DB_ARCHIVE_DIR="$TMP/db-archive"
  mkdir -p "$REPORT_DIR" "$DB_ARCHIVE_DIR"
  # shellcheck source=/dev/null
  source "$(repo_root)/aide/aide.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  return 0
}

# --- Codes de sortie ---------------------------------------------------------
# man aide : 1*(nouveaux) + 2*(supprimes) + 4*(modifies) ; 14 a 19 = erreur.

@test "code 0 : aucune difference" {
  [ "$(classify_aide_rc 0)" = "OK" ]
  [[ "$(describe_aide_rc 0)" == *"Aucune difference"* ]]
}

@test "code 1 : nouveaux fichiers seulement" {
  [ "$(classify_aide_rc 1)" = "ALERTE" ]
  run describe_aide_rc 1
  [[ "$output" == *"nouveaux fichiers"* ]]
  [[ "$output" != *"supprimes"* ]]
  [[ "$output" != *"modifies"* ]]
}

@test "code 7 : les trois types cumules" {
  [ "$(classify_aide_rc 7)" = "ALERTE" ]
  run describe_aide_rc 7
  [[ "$output" == *"nouveaux fichiers"* ]]
  [[ "$output" == *"fichiers supprimes"* ]]
  [[ "$output" == *"fichiers modifies"* ]]
}

@test "code 6 : supprimes + modifies, sans nouveaux" {
  run describe_aide_rc 6
  [[ "$output" != *"nouveaux"* ]]
  [[ "$output" == *"fichiers supprimes"* ]]
  [[ "$output" == *"fichiers modifies"* ]]
}

@test "codes 14 et superieurs : erreur d'execution, pas un resultat d'analyse" {
  [ "$(classify_aide_rc 14)" = "ERREUR" ]
  [ "$(classify_aide_rc 18)" = "ERREUR" ]
  [[ "$(describe_aide_rc 18)" == *"echoue"* ]]
}

@test "une erreur d'execution n'est jamais confondue avec un systeme conforme" {
  [ "$(classify_aide_rc 14)" != "$(classify_aide_rc 0)" ]
}

# --- Integrite de la base de reference ---------------------------------------

@test "base intacte : empreinte conforme" {
  echo "base" > "$AIDE_DB"
  store_db_hash
  run check_db_hash
  [ "$status" -eq 0 ]
  [[ "$output" == *"intacte"* ]]
}

@test "base regeneree hors procedure : detectee" {
  echo "base" > "$AIDE_DB"
  store_db_hash
  echo "base falsifiee" > "$AIDE_DB"
  run check_db_hash
  [ "$status" -eq 1 ]
  [[ "$output" == *"MODIFIEE HORS PROCEDURE"* ]]
}

@test "empreinte absente : signalee sans etre confondue avec une falsification" {
  echo "base" > "$AIDE_DB"
  run check_db_hash
  [ "$status" -eq 2 ]
}

# --- Rotation ----------------------------------------------------------------

@test "rotation : conserve les N rapports les plus recents" {
  for d in 2026-01-15T040000Z 2026-02-01T040000Z 2025-12-01T040000Z \
           2026-03-10T040000Z 2026-03-09T040000Z; do
    : > "$REPORT_DIR/aide-$d.txt"
  done

  rotate "$REPORT_DIR" 'aide-*.txt' 2

  [ "$(find "$REPORT_DIR" -name 'aide-*.txt' | wc -l)" -eq 2 ]
  [ -f "$REPORT_DIR/aide-2026-03-10T040000Z.txt" ]
  [ -f "$REPORT_DIR/aide-2026-03-09T040000Z.txt" ]
  [ ! -f "$REPORT_DIR/aide-2025-12-01T040000Z.txt" ]
}

@test "rotation : le format ISO garantit un tri chronologique" {
  # Avec l'ancien format %m-%d-%Y, "01-15-2026" precedait "12-01-2025" :
  # la rotation supprimait alors une sauvegarde arbitraire.
  : > "$REPORT_DIR/aide-2025-12-31T235959Z.txt"
  : > "$REPORT_DIR/aide-2026-01-01T000000Z.txt"

  rotate "$REPORT_DIR" 'aide-*.txt' 1

  [ -f "$REPORT_DIR/aide-2026-01-01T000000Z.txt" ]
  [ ! -f "$REPORT_DIR/aide-2025-12-31T235959Z.txt" ]
}

@test "rotation : repertoire vide, aucune erreur" {
  run rotate "$REPORT_DIR" 'aide-*.txt' 5
  [ "$status" -eq 0 ]
}
