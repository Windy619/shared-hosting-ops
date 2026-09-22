#!/usr/bin/env bash
# Fonctions communes aux suites bats.

# Racine du depot, quel que soit le repertoire d'invocation.
repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

# mktemp plutot que BATS_TEST_TMPDIR : cette variable n'existe qu'a partir de
# bats 1.4, et les depots Debian/Ubuntu embarquent encore des versions 1.2.
make_tmpdir() {
  mktemp -d "${TMPDIR:-/tmp}/aidetest.XXXXXX"
}

# Cree une release complete (avec vendor/autoload.php, donc jugee exploitable).
mk_release() {
  local dir="$1"
  mkdir -p "$dir/vendor" "$dir/public"
  : > "$dir/vendor/autoload.php"
}

# Cree une release incomplete : un deploiement interrompu avant composer.
mk_broken_release() {
  mkdir -p "$1/public"
}

# La structure Capistrano repose entierement sur de vrais liens symboliques.
# Git Bash sous Windows les simule par copie : les tests correspondants y
# seraient faussement rouges. On les saute explicitement plutot que de les
# neutraliser - sous Linux (et donc en CI) ils s'executent normalement.
require_symlinks() {
  local d f
  d="$(make_tmpdir)"
  mkdir -p "$d/cible"
  ln -s "$d/cible" "$d/lien" 2>/dev/null || true
  if [ -L "$d/lien" ]; then f=0; else f=1; fi
  rm -rf "$d"
  [ "$f" -eq 0 ] || skip "liens symboliques natifs indisponibles sur cette plateforme"
}
