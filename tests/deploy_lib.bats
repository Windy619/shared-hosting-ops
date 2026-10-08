#!/usr/bin/env bats
#
# deploy/remote/_lib.sh - structure Capistrano : bascule de current, choix de
# la release precedente, elagage.
#
# Ces fonctions sont partagees par le pipeline GitLab ET par le Makefile :
# une regression ici toucherait les deux chemins de deploiement a la fois.
# Elles necessitent de vrais liens symboliques, donc un systeme POSIX.

load helpers

setup() {
  require_symlinks
  TMP="$(make_tmpdir)"
  export PROJECT_DIR="$TMP/app"
  export KEEP_RELEASES=3
  mkdir -p "$PROJECT_DIR/releases" "$PROJECT_DIR/shared/storage"
  : > "$PROJECT_DIR/shared/.env"
  # shellcheck source=/dev/null
  source "$(repo_root)/recipes/laravel/deploy/remote/_lib.sh"
}

teardown() {
  # TMP n'est pas defini si setup s'est interrompu sur un skip : sans ce
  # garde, on lancerait `rm -rf ""`.
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  return 0
}

# --- Bascule de current ------------------------------------------------------

@test "publish_release : current pointe sur la release demandee" {
  mk_release "$PROJECT_DIR/releases/20260101000000"
  publish_release "$PROJECT_DIR/releases/20260101000000"

  [ -L "$CURRENT_LINK" ]
  [ "$(readlink -f "$CURRENT_LINK")" = "$(readlink -f "$PROJECT_DIR/releases/20260101000000")" ]
}

@test "publish_release : une bascule sur une release deja active est sans effet" {
  mk_release "$PROJECT_DIR/releases/20260101000000"
  mk_release "$PROJECT_DIR/releases/20260102000000"

  publish_release "$PROJECT_DIR/releases/20260101000000"
  publish_release "$PROJECT_DIR/releases/20260102000000"
  publish_release "$PROJECT_DIR/releases/20260102000000"

  [ "$(basename "$(readlink -f "$CURRENT_LINK")")" = "20260102000000" ]
}

@test "publish_release : aucun fichier temporaire ne subsiste" {
  mk_release "$PROJECT_DIR/releases/20260101000000"
  publish_release "$PROJECT_DIR/releases/20260101000000"
  [ ! -e "$CURRENT_LINK.tmp" ]
}

# --- Choix de la release precedente ------------------------------------------

@test "previous_release : retourne l'avant-derniere, pas l'active" {
  mk_release "$PROJECT_DIR/releases/20260101000000"
  mk_release "$PROJECT_DIR/releases/20260102000000"
  mk_release "$PROJECT_DIR/releases/20260103000000"
  publish_release "$PROJECT_DIR/releases/20260103000000"

  run previous_release
  [ "$status" -eq 0 ]
  [ "$(basename "$output")" = "20260102000000" ]
}

@test "previous_release : ignore une release sans vendor/" {
  # Un deploiement interrompu avant composer install laisse une release
  # inutilisable : basculer dessus produirait une erreur fatale PHP.
  mk_release "$PROJECT_DIR/releases/20260101000000"
  mk_broken_release "$PROJECT_DIR/releases/20260102000000"
  mk_release "$PROJECT_DIR/releases/20260103000000"
  publish_release "$PROJECT_DIR/releases/20260103000000"

  run previous_release
  [ "$status" -eq 0 ]
  [ "$(basename "$output")" = "20260101000000" ]
}

@test "previous_release : echoue proprement s'il n'y a aucune cible" {
  mk_release "$PROJECT_DIR/releases/20260101000000"
  publish_release "$PROJECT_DIR/releases/20260101000000"

  run previous_release
  [ "$status" -ne 0 ]
}

# --- Elagage -----------------------------------------------------------------

@test "cleanup_releases : conserve KEEP_RELEASES releases" {
  for d in 20260101000000 20260102000000 20260103000000 20260104000000 20260105000000; do
    mk_release "$PROJECT_DIR/releases/$d"
  done
  publish_release "$PROJECT_DIR/releases/20260105000000"

  cleanup_releases

  [ "$(find "$PROJECT_DIR/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 3 ]
  [ -d "$PROJECT_DIR/releases/20260105000000" ]
  [ ! -d "$PROJECT_DIR/releases/20260101000000" ]
}

@test "cleanup_releases : la release active est protegee meme si elle est ancienne" {
  # Cas d'un rollback : current pointe sur une release qui n'est plus parmi
  # les plus recentes. La supprimer casserait le site en production.
  for d in 20260101000000 20260102000000 20260103000000 20260104000000 20260105000000; do
    mk_release "$PROJECT_DIR/releases/$d"
  done
  publish_release "$PROJECT_DIR/releases/20260101000000"
  export KEEP_RELEASES=2

  cleanup_releases

  [ -d "$PROJECT_DIR/releases/20260101000000" ]
  [ "$(readlink -f "$CURRENT_LINK")" = "$(readlink -f "$PROJECT_DIR/releases/20260101000000")" ]
}

# --- Journal des revisions ---------------------------------------------------

@test "log_revision : une ligne horodatee, avec l'action et l'auteur" {
  export DEPLOYER="alice"
  export REVISION="abc1234"
  : > "$REVISIONS_LOG"

  log_revision "deploy" "20260101000000"

  run cat "$REVISIONS_LOG"
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"20260101000000"* ]]
  [[ "$output" == *"abc1234"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "log_revision : les entrees s'ajoutent sans ecraser les precedentes" {
  : > "$REVISIONS_LOG"
  log_revision "deploy" "20260101000000"
  log_revision "rollback" "20251231000000"
  [ "$(wc -l < "$REVISIONS_LOG")" -eq 2 ]
}

# --- Redemarrage des workers -------------------------------------------------
#
# supervisorctl n'existe pas sur un runner CI : ces tests verifient la commande
# qui AURAIT ete lancee, jamais son effet. Le faux sudo repond a `status` avec
# l'etat qu'on lui donne, et journalise tout le reste.

stub_supervisor() {
  mkdir -p "$TMP/bin"
  export SUDO_LOG="$TMP/sudo.log"
  export SUDO_RC="${1:-0}"
  export SUPERVISOR_STATUS="$TMP/status.txt"
  {
    echo '#!/usr/bin/env bash'
    echo 'exit 0'
  } > "$TMP/bin/supervisorctl"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [ "$2" = "status" ]; then cat "$SUPERVISOR_STATUS"; exit 0; fi'
    echo 'echo "$*" >> "$SUDO_LOG"'
    echo 'exit ${SUDO_RC:-0}'
  } > "$TMP/bin/sudo"
  chmod +x "$TMP/bin/supervisorctl" "$TMP/bin/sudo"
  : > "$SUPERVISOR_STATUS"
  PATH="$TMP/bin:$PATH"
}

# Declare des groupes dans le faux supervisor, au format de `supervisorctl status`.
declare_groups() {
  local g
  for g in "$@"; do
    echo "$g:${g}_00   RUNNING   pid 1, uptime 0:10:00" >> "$SUPERVISOR_STATUS"
  done
}

@test "restart_workers : sans SUPERVISOR_GROUPS, aucune commande n'est lancee" {
  stub_supervisor
  export SUPERVISOR_GROUPS=""

  run restart_workers

  [ "$status" -eq 0 ]
  [ ! -f "$TMP/sudo.log" ]
}

@test "restart_workers : un restart par groupe declare" {
  stub_supervisor
  declare_groups laravel-worker-prod laravel-reverb-prod
  export SUPERVISOR_GROUPS="laravel-worker-prod laravel-reverb-prod"

  run restart_workers

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/sudo.log")" -eq 2 ]
  grep -qxF 'supervisorctl restart laravel-worker-prod:*' "$TMP/sudo.log"
  grep -qxF 'supervisorctl restart laravel-reverb-prod:*' "$TMP/sudo.log"
}

@test "restart_workers : un groupe absent de supervisor est ignore, pas relance" {
  stub_supervisor
  declare_groups laravel-worker-prod
  export SUPERVISOR_GROUPS="laravel-worker-prod laravel-reverb-prod"

  run restart_workers

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/sudo.log")" -eq 1 ]
  grep -qxF 'supervisorctl restart laravel-worker-prod:*' "$TMP/sudo.log"
  [[ "$output" == *"laravel-reverb-prod non declare"* ]]
}

@test "restart_workers : un echec supervisorctl n'arrete pas le deploiement" {
  stub_supervisor 1
  declare_groups laravel-worker-prod
  export SUPERVISOR_GROUPS="laravel-worker-prod"

  run restart_workers

  [ "$status" -eq 0 ]
  [[ "$output" == *"echec"* ]]
}

@test "restart_workers : supervisorctl absent, le deploiement continue" {
  mkdir -p "$TMP/empty"
  export SUPERVISOR_GROUPS="laravel-worker-prod"

  saved_path="$PATH"
  PATH="$TMP/empty"
  run restart_workers
  PATH="$saved_path"

  [ "$status" -eq 0 ]
  [[ "$output" == *"supervisorctl absent"* ]]
}

@test "restart_workers : un etat supervisor illisible est signale" {
  stub_supervisor
  export SUPERVISOR_GROUPS="laravel-worker-prod"

  run restart_workers

  [ "$status" -eq 0 ]
  [ ! -f "$TMP/sudo.log" ]
  [[ "$output" == *"etat illisible"* ]]
}
