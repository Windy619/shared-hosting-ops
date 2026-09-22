#!/usr/bin/env bats
#
# docker_backup.sh - rotation par palier et normalisation des noms d'archive.
#
# La version d'origine triait les sauvegardes au format %d-%m-%Y avec
# `ls | sort | head -n 1` : "01-12-2025" se classait avant "02-01-2024", si
# bien que la rotation pouvait supprimer la sauvegarde la PLUS RECENTE.

load helpers

setup() {
  TMP="$(make_tmpdir)"
  export BACKUP_ROOT="$TMP"
  export CONTAINERS="fake"
  # shellcheck source=/dev/null
  source "$(repo_root)/docker-backup/docker_backup.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  return 0
}

# --- Rotation ----------------------------------------------------------------

@test "rotation : conserve les N sauvegardes les plus recentes" {
  mkdir -p "$TMP/daily"
  for d in 2026-01-15T020000Z 2026-02-01T020000Z 2025-12-01T020000Z \
           2026-03-10T020000Z 2026-03-09T020000Z; do
    mkdir -p "$TMP/daily/$d"
  done

  rotate "$TMP/daily" 2

  [ "$(find "$TMP/daily" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]
  [ -d "$TMP/daily/2026-03-10T020000Z" ]
  [ -d "$TMP/daily/2026-03-09T020000Z" ]
  [ ! -d "$TMP/daily/2025-12-01T020000Z" ]
}

@test "rotation : la plus recente survit meme si elle est la derniere creee" {
  # Reproduit precisement le bug d'origine : en tri lexicographique sur
  # %d-%m-%Y, "02-01-2024" passait avant "01-12-2025".
  mkdir -p "$TMP/daily/2024-01-02T020000Z" "$TMP/daily/2025-12-01T020000Z"

  rotate "$TMP/daily" 1

  [ -d "$TMP/daily/2025-12-01T020000Z" ]
  [ ! -d "$TMP/daily/2024-01-02T020000Z" ]
}

@test "rotation : conserver plus que present ne supprime rien" {
  mkdir -p "$TMP/daily/2026-03-10T020000Z"
  rotate "$TMP/daily" 10
  [ -d "$TMP/daily/2026-03-10T020000Z" ]
}

@test "rotation : palier vide, aucune erreur" {
  mkdir -p "$TMP/weekly"
  run rotate "$TMP/weekly" 3
  [ "$status" -eq 0 ]
}

# --- Noms d'archive ----------------------------------------------------------

@test "safe_name : un chemin de volume devient un nom de fichier valide" {
  [ "$(safe_name '/var/lib/docker/volumes/data')" = "var_lib_docker_volumes_data" ]
}

@test "safe_name : les espaces ne cassent pas le nom" {
  run safe_name '/srv/mon dossier/data'
  [[ "$output" != *" "* ]]
}

@test "safe_name : les caracteres exotiques sont neutralises" {
  run safe_name '/srv/aaa:bbb$ccc'
  [[ "$output" != *":"* ]]
  [[ "$output" != *'$'* ]]
}

# --- Verification d'archive --------------------------------------------------

@test "verify_archive : accepte une archive valide" {
  mkdir -p "$TMP/src" && echo contenu > "$TMP/src/f.txt"
  tar -C "$TMP/src" -czf "$TMP/a.tar.gz" .
  run verify_archive "$TMP/a.tar.gz"
  [ "$status" -eq 0 ]
}

@test "verify_archive : rejette une archive tronquee" {
  mkdir -p "$TMP/src" && head -c 4096 /dev/urandom > "$TMP/src/f.bin"
  tar -C "$TMP/src" -czf "$TMP/a.tar.gz" .
  # On coupe l'archive en deux : le flux gzip devient invalide.
  truncate -s 20 "$TMP/a.tar.gz"
  run verify_archive "$TMP/a.tar.gz"
  [ "$status" -ne 0 ]
}

# --- Interface ---------------------------------------------------------------

@test "un palier inconnu est refuse" {
  run bash "$(repo_root)/docker-backup/docker_backup.sh" hourly
  [ "$status" -ne 0 ]
}

@test "sans argument, le script sort en erreur" {
  # Un cron mal configure doit etre bruyant, pas silencieux.
  run bash "$(repo_root)/docker-backup/docker_backup.sh"
  [ "$status" -ne 0 ]
}
