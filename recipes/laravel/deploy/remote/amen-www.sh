#!/usr/bin/env bash
# =============================================================================
# amen-www.sh - docroot physique impose par l'hebergeur (type AmenPanel).
#
# Certains mutualises exigent que le DocumentRoot soit un repertoire REEL
# (www/), impossible a remplacer par un lien vers current/public. On y pose
# donc un front controller et trois liens qui pointent a travers `current` :
# ils suivent donc automatiquement chaque nouvelle release.
#
#   www/
#   |-- index.php    genere depuis public/index.php, chemins reecrits
#   |-- .htaccess    copie de public/.htaccess
#   |-- build   -> current/public/build
#   |-- img     -> current/public/img
#   |-- storage -> shared/storage/app/public
#   `-- document, img_back, favicons...   PHYSIQUES, jamais touches
#
# REGLE D'OR : www/ n'est JAMAIS supprime ni recree. Tout element physique
# existant est detecte et conserve tel quel.
#
# MODE = link (defaut) | init | audit
# Concatene apres _lib.sh.
# =============================================================================

MODE="${MODE:-link}"
FORCE="${FORCE:-}"
WWW_PATH="${WWW_PATH:-$PROJECT_DIR/www}"

case "$WWW_PATH" in
  /*) ;;
   *) WWW_PATH="$PROJECT_DIR/$WWW_PATH" ;;
esac

# --- Pose un lien sans jamais ecraser un element physique --------------------
relink() {
  local link="$1" target="$2" name
  name="$(basename "$link")"

  if [ -e "$link" ] && [ ! -L "$link" ]; then
    warn "$name : element PHYSIQUE -> conserve, aucun lien pose"
    return 0
  fi

  ln -nfs "$target" "$link"
  if [ -e "$link" ]; then
    ok "$name -> $target"
  else
    warn "$name -> $target  [LIEN CASSE : la cible n'existe pas]"
  fi
}

# =============================================================================
case "$MODE" in

# --- Pose / repose les liens du docroot -------------------------------------
link)
  phase "docroot : liens"
  [ -d "$WWW_PATH" ] || die "docroot absent : $WWW_PATH"

  relink "$WWW_PATH/build"   "$CURRENT_LINK/public/build"
  relink "$WWW_PATH/img"     "$CURRENT_LINK/public/img"
  relink "$WWW_PATH/storage" "$SHARED_DIR/storage/app/public"

  # Ces liens passent par `current` : une nouvelle release est suivie
  # automatiquement, sans avoir a les reposer.
  ;;

# --- Genere index.php et .htaccess s'ils manquent ---------------------------
init)
  phase "docroot : front controller"
  [ -d "$WWW_PATH" ] || die "docroot absent : $WWW_PATH"
  [ -e "$CURRENT_LINK" ] || die "aucune release active : deployez d'abord"

  if [ -f "$WWW_PATH/index.php" ] && [ -z "$FORCE" ]; then
    log "= index.php deja en place (FORCE=1 pour regenerer)"
  else
    src="$CURRENT_LINK/public/index.php"
    [ -f "$src" ] || die "introuvable : $src"

    # public/index.php reference ../vendor et ../bootstrap ; depuis www/ il
    # faut viser ../current/vendor et ../current/bootstrap.
    sed "s|__DIR__\.'/\.\./|__DIR__.'/../current/|g" "$src" > "$WWW_PATH/index.php.new"

    # Garde-fou : la forme de public/index.php change entre versions de
    # Laravel. Si la reecriture n'a pas produit le chemin attendu, on
    # abandonne plutot que d'installer un front controller casse.
    if ! grep -q "current/vendor/autoload.php" "$WWW_PATH/index.php.new"; then
      rm -f "$WWW_PATH/index.php.new"
      die "reecriture de index.php incorrecte : aucun 'current/vendor/autoload.php' produit.
  La structure de public/index.php a probablement change ; adaptez le sed."
    fi

    mv -f "$WWW_PATH/index.php.new" "$WWW_PATH/index.php"
    ok "index.php genere"
  fi

  if [ -f "$WWW_PATH/.htaccess" ] && [ -z "$FORCE" ]; then
    log "= .htaccess deja en place"
  else
    cp -f "$CURRENT_LINK/public/.htaccess" "$WWW_PATH/.htaccess"
    ok ".htaccess pose"
  fi
  ;;

# --- Audit du docroot -------------------------------------------------------
audit)
  phase "docroot : contenu de $WWW_PATH"
  ls -la "$WWW_PATH"

  phase "fichiers .php a la racine du docroot"
  # Seul index.php est legitime ici. Tout autre .php dans un docroot
  # mutualise merite une verification immediate.
  found=0
  for f in "$WWW_PATH"/*.php; do
    [ -e "$f" ] || continue
    found=1
    if [ "$(basename "$f")" = "index.php" ]; then
      ok "index.php (attendu)"
    else
      warn "$(basename "$f") : INATTENDU - a verifier"
    fi
  done
  [ "$found" -eq 1 ] || log "aucun fichier .php"

  phase "resolution des liens"
  for l in build img storage; do
    p="$WWW_PATH/$l"
    if [ -L "$p" ]; then
      if [ -e "$p" ]; then
        ok "$l -> $(readlink "$p")"
      else
        warn "$l -> $(readlink "$p")  [CASSE]"
      fi
    elif [ -e "$p" ]; then
      log "$l : element physique"
    else
      warn "$l : absent"
    fi
  done
  ;;

*)
  die "MODE inconnu : $MODE (attendu : link, init ou audit)"
  ;;
esac
