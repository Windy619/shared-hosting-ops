# laravel

Déploiement Laravel sans interruption sur hébergement mutualisé, suivant la
structure [Capistrano](https://capistranorb.com/documentation/getting-started/structure/),
par **pipeline GitLab** ou par **Makefile en SSH direct**.

Les deux partagent la même logique distante (`deploy/remote/`) : le choix entre
les deux dépend de ce que le serveur du client tolère, pas du comportement voulu.

```
<projet>/
├── current -> releases/20260918120000   bascule atomique, en FIN de déploiement
├── releases/                            les KEEP_RELEASES dernières, complètes
├── shared/                              .env, storage, configuration persistante
├── backup/                              dumps SQL avant migration
├── revisions.log                        qui a déployé quoi, et quand
└── www/                                 docroot physique, si l'hébergeur l'impose
```

## Ce qu'il faut copier dans le projet

| Fichier d'ici | Où le déposer | Quand |
|---|---|---|
| `deploy/remote/*.sh` | `deploy/remote/` du projet | toujours, c'est la logique distante |
| `.gitlab-ci.yml` | racine du projet | déploiement par pipeline GitLab |
| `Makefile` | racine du projet | déploiement par Makefile en SSH direct |
| `config.mk.example` | racine du projet, copié en `config.mk` | avec le Makefile, `config.mk` n'est jamais versionné |
| `init_server.sh` | rien à copier, s'exécute une fois sur le serveur | première mise en place d'un environnement |

Les deux points d'entrée partagent `deploy/remote/` : ne prendre que l'un des
deux reste valable, laisser tomber `deploy/` ne l'est jamais.

```bash
cp .gitlab-ci.yml Makefile config.mk.example <projet>/
cp -r deploy       <projet>/
cd <projet> && cp config.mk.example config.mk    # puis renseigner les valeurs
```

Puis, une seule fois par environnement :

```bash
bash init_server.sh app.example.com   # arborescence + shared/ + squelette storage
make init CONFIRM=yes                 # variante depuis le poste de dev
```

### Variables CI à définir dans GitLab

| Variable | Rôle |
|---|---|
| `SSH_PRIVATE_KEY` | Clé de déploiement - masquée, protégée |
| `SSH_USER`, `SSH_HOST`, `SSH_PORT` | Accès SSH - protégées |
| `SSH_KNOWN_HOSTS` | Sortie de `ssh-keyscan -p <port> <hôte>` |

Le job **échoue volontairement** si `SSH_KNOWN_HOSTS` est absente, avec la marche
à suivre. Utilisez une clé distincte par environnement : une clé unique fait d'un
accès `develop` un accès production.

## Usage

```bash
make deploy CONFIRM=yes      # déploiement complet
make rollback CONFIRM=yes    # retour à la release précédente
make revisions               # journal des déploiements
make www-audit               # docroot : liens, éléments physiques, .php suspects
make db-backup               # dump SQL manuel hors cycle de déploiement
make db-restore CONFIRM=yes CONFIRM_RESTORE=RESTORE [DUMP=db-....sql.gz]
```

`make help` liste les cibles - l'aide est générée depuis les commentaires `##`,
elle ne peut donc pas se désynchroniser.

---

## Décisions

### La bascule de `current` arrive en dernier

Le flow Capistrano place `composer install` et les migrations dans
`deploy:updated`, et la bascule dans `deploy:publishing` - **après**. Tant que la
bascule n'a pas eu lieu, un échec à n'importe quelle étape laisse le site intact.

Une version antérieure basculait `current` *avant* `composer install` : pendant
toute sa durée, `current` pointait vers une release sans `vendor/`. Le mode
maintenance ne suffit pas, car afficher la page 503 de Laravel nécessite
`vendor/autoload.php` - le visiteur recevait une erreur fatale PHP.

Un `trap EXIT` supprime la release partielle en cas d'interruption : elle ne doit
ni encombrer `releases/`, ni devenir une cible de rollback.

### Les releases restent dans `releases/`

Déplacer l'ancienne release vers `backup/` à chaque déploiement, comme le faisait
la version d'origine, impose de la rapatrier par `cp -a` lors d'un rollback :
plusieurs centaines de mégaoctets à copier, site en maintenance pendant ce temps,
et un seul niveau de retour.

En laissant les releases sur place, le rollback se réduit à un `ln -nfs`. Il est
instantané, et il y a autant de niveaux de retour que de releases conservées.
`backup/` ne sert plus qu'aux dumps SQL - un répertoire, une seule règle de
rotation.

### `deploy:check` refuse de déployer sur un environnement incomplet

`ln -s` vers une cible inexistante **réussit** : il crée un lien mort, sans
erreur. C'est ainsi qu'un `shared/.user.ini` manquant a pu faire que la
configuration PHP n'était jamais appliquée, sans que rien ne le signale.

`check.sh` valide donc, avant tout transfert : présence de chaque `linked_file`
et `linked_dir`, `APP_KEY` non vide, permissions du `.env` (corrigées en 600 si
nécessaire), binaires PHP et Composer, `storage/` inscriptible, espace disque.

### `config:cache` et `route:cache` sont désactivés par défaut

`config:cache` casse l'application si `env()` est appelé ailleurs que dans
`config/`, et `route:cache` échoue s'il existe une route en closure. Les activer
silencieusement reviendrait à parier sur le code applicatif.

`view:cache` est sans risque et toujours appliqué. Les deux autres s'activent
par `ENABLE_CONFIG_CACHE=1`, en connaissance de cause.

### Le redémarrage des workers est explicite, pas supposé

`queue:restart` est un signal coopératif : le worker sort en code 0 à la fin de
son job courant. Une configuration Supervisor en `autorestart=unexpected`, qui
est la valeur par défaut, considère cette sortie comme attendue et ne relance
rien. Les workers restent alors éteints pendant que le déploiement s'annonce
réussi. Un serveur Reverb, lui, n'écoute même pas ce signal.

`SUPERVISOR_GROUPS` liste des groupes candidats, pas une vérité. Le déploiement
interroge d'abord `supervisorctl status` et ne relance que ceux qui y sont
déclarés : le même pipeline sert un projet avec workers et Reverb, un projet
avec workers seuls, et un projet qui n'en a aucun. Variable vide, rien n'est
interrogé.

Le `sudo` se limite à cette seule commande, côté serveur :

```
deploy ALL=(root) NOPASSWD: /usr/bin/supervisorctl status, /usr/bin/supervisorctl restart *
```

### Le dump SQL est validé, pas seulement produit

Un `gzip` de flux vide pèse une vingtaine d'octets : `test -s` le déclare donc
valide. C'est ainsi qu'un dump vide pouvait précéder une migration.

`db_backup` active `pipefail`, ne masque plus les erreurs de `mysqldump`, et
vérifie `gzip -t` puis la présence du marqueur `Dump completed` en fin d'archive.
Le mot de passe passe par `MYSQL_PWD`, jamais par `-p...`, pour ne pas apparaître
dans `ps`.

Un dump impossible (`DB_DATABASE` absent, `mysqldump` introuvable) fait échouer
le déploiement : on ne migre pas sans filet par accident. Pour s'en passer, il
faut le demander : `DB_BACKUP=0`.

### Trois familles de dumps

| Fichier | Quand | Rotation |
|---|---|---|
| `db-pre-<release>.sql.gz` | avant la migration d'un déploiement, nommé d'après la release déployée | `KEEP_DUMPS` (10) |
| `db-manual-<horodatage>.sql.gz` | `make db-backup` | `KEEP_DUMPS` (10), quota séparé |
| `db-safety-<horodatage>.sql.gz` | juste avant une restauration | jamais élagué |

Chaque quota est indépendant : des dumps manuels n'évincent plus ceux d'avant
migration. Le nom du dump d'avant migration est noté dans `revisions.log`
(`dump db-pre-...`). Les dumps de sécurité ne sont pas élagués : à supprimer à la
main une fois la restauration validée.

**Les dumps sont sur le même serveur que la base.** Ils servent de filet avant
migration, pas de sauvegarde contre la perte du serveur. Une copie hors du
serveur n'entre pas dans cette recette.

### La base n'est jamais restaurée automatiquement

Un rollback restaure le code, jamais la base : rejouer un dump détruirait tout ce
qui a été écrit depuis. Code et base se restaurent séparément, chacun derrière son
propre verrou. Après une migration destructrice, le rollback seul ne suffit pas :
il affiche le dump `db-pre-<release>` correspondant s'il existe.

La restauration se fait par `make db-restore CONFIRM=yes CONFIRM_RESTORE=RESTORE`,
ou par le job manuel `db_restore_<env>` du CI (variable `CONFIRM_RESTORE=RESTORE`
obligatoire). `DUMP=db-....sql.gz` choisit le fichier ; par défaut, le plus récent
des dumps avant migration et manuels. Pour revenir de deux releases, prendre dans
`make revisions` le dump de la plus ancienne release annulée.

Avant d'importer, la restauration :

1. vérifie le fichier (`gzip -t`, marqueur `Dump completed`) : une archive
   tronquée est refusée sans toucher à la base ;
2. passe le site en maintenance ;
3. prend un dump de sécurité de l'état courant, pour pouvoir annuler
   (`DUMP=db-safety-...`) ;
4. supprime toutes les tables de la base : un `mysqldump` ne fait `DROP`/`CREATE`
   que pour ses propres tables, celles créées par la migration fautive
   subsisteraient et le `migrate` suivant échouerait sur « table already exists ».

### Écarts assumés vis-à-vis de Capistrano

**Pas de `repo/`** : le CI construit et livre une archive. Le serveur n'a ni git,
ni accès au dépôt - sur un mutualisé, c'est un avantage, pas une contrainte.

**`shared/` à plat** au lieu de refléter l'arborescence des releases : hérité des
serveurs déjà en place. La correspondance est explicite dans `_lib.sh`
(`LINKED_FILES_MAP`), donc modifiable sans toucher au code.

### Le docroot physique imposé (`amen-www.sh`)

Certains mutualisés exigent que le DocumentRoot soit un répertoire réel,
impossible à remplacer par un lien vers `current/public`. On y pose un front
controller et trois liens qui pointent *à travers* `current` : ils suivent donc
automatiquement chaque release, sans avoir à être reposés.

Règle absolue : `www/` n'est jamais supprimé ni recréé. Tout élément physique
existant (`document/`, `img_back/`, favicons) est détecté et conservé. Le
`sed` qui réécrit `index.php` vérifie son propre résultat et abandonne si la
réécriture n'a pas produit le chemin attendu, la structure de `public/index.php`
changeant d'une version de Laravel à l'autre.

`make www-audit` liste le docroot et signale tout `.php` autre qu'`index.php` :
un docroot mutualisé est une cible classique de dépôt de webshell.
