# =============================================================================
# Deploiement Laravel par SSH - modele Capistrano
#
#   Structure : https://capistranorb.com/documentation/getting-started/structure/
#   Flow      : https://capistranorb.com/documentation/getting-started/flow/
#
# Pour les serveurs clients trop contraints pour heberger un runner CI : le
# poste de developpement joue le role du runner, la logique distante est
# STRICTEMENT LA MEME que celle du pipeline GitLab (deploy/remote/*.sh).
# C'est ce partage qui empeche les deux implementations de diverger.
#
#   $(PROJECT_PATH)/
#   |-- current -> releases/20260918120000   bascule en FIN de deploiement
#   |-- releases/                            les KEEP_RELEASES dernieres
#   |-- shared/                              .env + storage persistants
#   |-- backup/                              dumps SQL
#   |-- revisions.log                        journal des deploys/rollbacks
#   `-- www/                                 docroot physique impose (Amen)
#
# REGLE D'OR : www/ n'est jamais supprime ni recree. Voir `make www-audit`.
#
# Configuration : copiez config.mk.example en config.mk (hors depot).
# =============================================================================

-include config.mk

# --- Valeurs par defaut (surchargees par config.mk) --------------------------
HOST          ?= prod
PROJECT_PATH  ?= /srv/app
WWW_PATH      ?= $(PROJECT_PATH)/www
PHP_BIN       ?= php
COMPOSER_BIN  ?= composer
APP_URL       ?= https://example.com
BRANCH        ?= main
KEEP_RELEASES ?= 3
KEEP_DUMPS    ?= 10
SSH_MUX       ?= 0

# Groupes Supervisor relances en fin de deploiement, separes par des espaces.
# Vide : les workers ne sont pas touches.
SUPERVISOR_GROUPS ?=

# --- Interrupteurs de deploiement --------------------------------------------
MIGRATE       ?= 1
DB_BACKUP     ?= 1
ENABLE_CONFIG_CACHE ?= 0

# --- Derive ------------------------------------------------------------------
REMOTE        := deploy/remote
RELEASE_NAME  := $(shell date -u +%Y%m%d%H%M%S)
ARCHIVE       := $(RELEASE_NAME).tar.gz
# L'archive est ecrite HORS du repertoire archive. La creer a la racine du
# projet modifiait la mtime de "." pendant que tar le lisait : tar signalait
# "file changed as we read it" et sortait en code 1, ce qui echouait le build.
BUILD_DIR     ?= /tmp
ARCHIVE_PATH  := $(BUILD_DIR)/$(ARCHIVE)
# Le nom est repris tel quel dans revisions.log ET dans le prefixe d'env de la
# commande SSH : on retire guillemets et apostrophes, qui casseraient la
# citation ("O'Brien" refermerait la chaine).
DEPLOYER      := $(shell { git config user.name 2>/dev/null || echo make; } | tr -d "'\"")
REVISION      := $(shell git rev-parse --short HEAD 2>/dev/null || echo inconnue)
MIGRATE_CMD   := $(if $(filter 1,$(MIGRATE)),migrate,)

# Correspondance shared/ -> release, format "source:destination".
# Layout plus simple que celui du pipeline : ici .htaccess et php.ini sont
# geres par le docroot www/, pas par des liens dans la release.
LINKED_FILES_MAP := .env:.env
LINKED_DIRS_MAP  := storage:storage

# --- SSH ---------------------------------------------------------------------
# Le multiplexage reutilise une connexion unique pour tout le deploiement.
# Opt-in : OpenSSH pour Windows ne le supporte pas.
ifeq ($(SSH_MUX),1)
SSH_MUX_OPTS := -o ControlMaster=auto -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=120
endif
SSH := ssh -o ConnectTimeout=15 $(SSH_MUX_OPTS)
SCP := scp -o ConnectTimeout=15 $(SSH_MUX_OPTS)

# Variables transmises a tous les scripts distants.
REMOTE_ENV := PROJECT_DIR='$(PROJECT_PATH)' PHP_BIN='$(PHP_BIN)' \
              COMPOSER_BIN='$(COMPOSER_BIN)' KEEP_RELEASES='$(KEEP_RELEASES)' \
              KEEP_DUMPS='$(KEEP_DUMPS)' \
              LINKED_FILES_MAP='$(LINKED_FILES_MAP)' LINKED_DIRS_MAP='$(LINKED_DIRS_MAP)' \
              WWW_PATH='$(WWW_PATH)' DEPLOYER='$(DEPLOYER)' REVISION='$(REVISION)' \
              SUPERVISOR_GROUPS='$(SUPERVISOR_GROUPS)'

# Envoie _lib.sh + <script> au serveur par stdin. Aucun echappement imbrique :
# les parametres passent par variables d'environnement.
#   $(1) = script de deploy/remote/   $(2) = variables supplementaires
define remote
cat $(REMOTE)/_lib.sh $(REMOTE)/$(1) | $(SSH) $(HOST) "$(REMOTE_ENV) $(2) bash -s"
endef

.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help check-connection init build-assets build deploy rollback \
        link-www www-init www-audit db-backup db-restore clean-releases \
        revisions health down up logs guard

# =============================================================================
help: ## Affiche cette aide
	@echo "Utilisation : make [cible] [OPTION=valeur]"
	@echo ""
	@echo "  Serveur : $(HOST)"
	@echo "  Chemin  : $(PROJECT_PATH)"
	@echo "  Docroot : $(WWW_PATH)"
	@echo "  URL     : $(APP_URL)"
	@echo ""
	@echo "Cibles :"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Options :"
	@echo "  MIGRATE=0             ne pas lancer les migrations"
	@echo "  DB_BACKUP=0           pas de dump SQL avant migration (sinon un dump impossible echoue le deploiement)"
	@echo "  KEEP_DUMPS=10         dumps conserves par prefixe (avant migration, manuel)"
	@echo "  DUMP=db-....sql.gz    dump a restaurer avec db-restore, le dernier par defaut"
	@echo "  CONFIRM_RESTORE=RESTORE  second verrou de db-restore"
	@echo "  ENABLE_CONFIG_CACHE=1 activer config:cache et route:cache"
	@echo "  CONFIRM=yes           requis pour deploy, rollback et db-restore"
	@echo "  FORCE=1               regenerer www/index.php et www/.htaccess"

# --- Garde-fou production ----------------------------------------------------
# Ces cibles agissent sur la PRODUCTION. Une confirmation explicite evite le
# declenchement accidentel, sans bloquer un usage scripte.
guard:
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo ""; \
		echo "  Cette commande agit sur la PRODUCTION ($(HOST))."; \
		echo "  Relancez avec :  make $(MAKECMDGOALS) CONFIRM=yes"; \
		echo ""; \
		exit 1; \
	fi

# =============================================================================
check-connection: ## Verifie l'acces SSH et la version de PHP distante
	@echo "Connexion a $(HOST)..."
	@$(SSH) $(HOST) "echo '  Connexion OK'; $(PHP_BIN) -r 'echo \"  PHP CLI \" . PHP_VERSION . PHP_EOL;'"

init: check-connection ## Prepare releases/ shared/ backup/ www/ (une seule fois)
	@$(call remote,init.sh,EXTRA_DIRS='www')

# =============================================================================
build-assets: ## Compile les assets front en local (npm ci + npm run build)
	@echo "Verification de la branche courante..."
	@git rev-parse --abbrev-ref HEAD | grep -qx "$(BRANCH)" || \
		(echo "ERREUR : vous n'etes pas sur la branche $(BRANCH)" && exit 1)
	npm ci --include=dev --no-audit --no-fund
	npm run build
	@test -f public/build/manifest.json || \
		(echo "ERREUR : public/build/manifest.json introuvable apres le build" && exit 1)

build: build-assets ## Archive le projet (code + assets compiles)
	@echo "Archivage..."
	@tar -czf $(ARCHIVE_PATH) \
		--exclude=./.git \
		--exclude=./.gitignore \
		--exclude=./.gitlab-ci.yml \
		--exclude=./.github \
		--exclude=./.vscode \
		--exclude=./.idea \
		--exclude=./deploy \
		--exclude=./node_modules \
		--exclude=./vendor \
		--exclude=./tests \
		--exclude=./storage \
		--exclude='./.env*' \
		--exclude=./Makefile \
		--exclude=./config.mk \
		--exclude=./phpunit.xml \
		--exclude='./_ide_helper*.php' \
		--exclude='./*.tar.gz' \
		.
	@echo "  Archive : $(ARCHIVE_PATH) ($$(du -h $(ARCHIVE_PATH) | cut -f1))"

# =============================================================================
## Deploiement complet.
## Tout ce qui est long (transfert, composer, dump SQL) se deroule site
## OUVERT ; seules les migrations et la bascule se font en maintenance.
## Un echec avant la bascule laisse `current` intact sur l'ancienne release.
# =============================================================================
deploy: guard check-connection build ## Deploie une nouvelle release
	@echo ""
	@echo "=== Release $(RELEASE_NAME) sur $(HOST) ($(REVISION)) ==="
	@echo ""
	@echo "[1/5] deploy:check"
	@$(call remote,check.sh)
	@echo ""
	@echo "[2/5] Transfert de l'archive"
	@$(SCP) -q $(ARCHIVE_PATH) $(HOST):$(PROJECT_PATH)/releases/
	@rm -f $(ARCHIVE_PATH)
	@echo ""
	@echo "[3/5] deploy:updating -> deploy:finishing"
	@$(call remote,deploy.sh,RELEASE_NAME='$(RELEASE_NAME)' ARCHIVE='$(ARCHIVE)' \
		MIGRATE_CMD='$(MIGRATE_CMD)' COMPOSER_FLAGS='--no-dev' \
		DB_BACKUP='$(DB_BACKUP)' ENABLE_CONFIG_CACHE='$(ENABLE_CONFIG_CACHE)')
	@echo ""
	@echo "[4/5] Docroot"
	@$(call remote,amen-www.sh,MODE='link')
	@$(call remote,amen-www.sh,MODE='init' FORCE='$(FORCE)')
	@echo ""
	@echo "[5/5] Controle HTTP"
	@$(MAKE) --no-print-directory health
	@echo ""
	@echo "Deploiement reussi : $(RELEASE_NAME)"

rollback: guard check-connection ## Revient a la release precedente
	@$(call remote,rollback.sh)
	@$(call remote,amen-www.sh,MODE='link')
	@$(MAKE) --no-print-directory health

# =============================================================================
link-www: ## (Re)pose les liens build/img/storage dans www (idempotent)
	@$(call remote,amen-www.sh,MODE='link')

www-init: ## Pose www/index.php et www/.htaccess s'ils sont absents
	@$(call remote,amen-www.sh,MODE='init' FORCE='$(FORCE)')

www-audit: ## Audit du docroot : liens, elements physiques, .php suspects
	@$(call remote,amen-www.sh,MODE='audit')

# =============================================================================
db-backup: ## Dump SQL manuel compresse dans backup/
	@$(call remote,db-backup.sh)

db-restore: guard ## Restaure un dump SQL (DUMP=db-....sql.gz, le dernier par defaut) - DESTRUCTIF
	@$(call remote,db-restore.sh,CONFIRM_RESTORE='$(CONFIRM_RESTORE)' DUMP='$(DUMP)')

# =============================================================================
clean-releases: ## Supprime les vieilles releases (garde KEEP_RELEASES dernieres)
	@$(call remote,cleanup.sh)

revisions: ## Affiche revisions.log (qui a deploye quoi, et quand)
	@$(call remote,revisions.sh,LINES='$(or $(LINES),20)')

# =============================================================================
health: ## Verifie le code HTTP de l'application
	@CODE=$$(curl -sS -o /dev/null -m 25 -w '%{http_code}' -L "$(APP_URL)" 2>/dev/null || true); \
	echo "  HTTP $$CODE  $(APP_URL)"; \
	case $$CODE in \
		200|301|302) echo "  Site operationnel." ;; \
		*) echo "  ATTENTION : reponse inattendue, voir make logs"; exit 1 ;; \
	esac

down: ## Bascule le site en maintenance
	@$(SSH) $(HOST) "cd $(PROJECT_PATH)/current && $(PHP_BIN) artisan down --retry=30"

up: ## Remet le site en ligne
	@$(SSH) $(HOST) "cd $(PROJECT_PATH)/current && $(PHP_BIN) artisan up"

logs: ## Suit les derniers logs applicatifs
	@$(SSH) $(HOST) "tail -n 100 -f $(PROJECT_PATH)/shared/storage/logs/*.log 2>/dev/null || echo 'Aucun log trouve.'"

