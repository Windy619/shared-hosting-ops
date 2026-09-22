# docker-backup

Sauvegarde des volumes Docker : cohérente, vérifiée, chiffrable, et surtout
**restaurable**.

```bash
docker_backup.sh daily|weekly|monthly     # effectue une sauvegarde
docker_backup.sh list                     # sauvegardes présentes et leur état
docker_backup.sh verify <répertoire>      # contrôle d'intégrité
docker_backup.sh restore <répertoire>     # restauration des volumes
```

## Installation

```bash
cp docker-backup.conf.example /etc/docker-backup.conf
chmod 600 /etc/docker-backup.conf         # contient éventuellement des secrets
install -m 750 docker_backup.sh /usr/local/bin/
```

Crontab - **c'est cron qui décide du palier**, pas le script :

```cron
0 2  * * 1-6  /usr/local/bin/docker_backup.sh daily
0 2  * * 7    /usr/local/bin/docker_backup.sh weekly
0 3  1 * *    /usr/local/bin/docker_backup.sh monthly
```

Avec systemd, préférez des timers `OnCalendar` avec `Persistent=true` : ils
rattrapent les exécutions manquées, ce que cron ne fait pas.

---

## Décisions

### Le palier est un argument, jamais une déduction

La version d'origine déterminait le type de sauvegarde en lisant l'heure
courante (`[ "$CURRENT_HOUR" -eq "$DAILY_CRON_HOUR" ]`). Trois conséquences :
un couplage implicite avec une crontab absente du dépôt ; aucune sauvegarde si
la machine avait redémarré ou si cron décalait d'une minute ; et l'impossibilité
de lancer une sauvegarde à la main pour la tester.

Elle contenait aussi cette condition :

```bash
if [ "$IS_FRIDAY" = false ] || [ "$IS_FRIDAY" = true ] && [ ... ]; then
```

`&&` et `||` ont la même priorité en bash, associativité à gauche : l'expression
se lit `((A || B) && C)`, et `A || B` est une tautologie. La sauvegarde
quotidienne s'exécutait donc aussi le vendredi. L'intention n'a jamais été
réalisée - et n'aurait pas pu l'être sous cette forme.

### Les dates sont en ISO 8601, ce qui n'est pas cosmétique

La rotation triait les répertoires au format `%d-%m-%Y` :

```
01-12-2025  02-01-2026  15-06-2025     ordre obtenu
15-06-2025  01-12-2025  02-01-2026     ordre chronologique réel
```

`ls | sort | head -n 1` désignait donc une sauvegarde arbitraire - parfois la
plus récente. En ISO 8601, le tri lexicographique **est** le tri chronologique.
La correction tient dans le format de date ; deux tests la verrouillent.

La boucle `while ... ; do rm -rf ... ; done` a également disparu : si `rm` échouait,
elle tournait indéfiniment. On parcourt désormais une liste finie.

### Les volumes ne sont pas copiés à chaud

`cp -r` sur un volume pendant que le conteneur y écrit produit une archive
incohérente. Pour une base de données, elle ne se restaure pas - et rien ne le
signale avant le jour où on en a besoin.

`STOP_MODE` vaut `pause` par défaut (le conteneur est figé le temps de
l'archivage), `stop` pour un arrêt propre, ou `none` pour des volumes inertes.
Un `trap EXIT` garantit que le conteneur repart même si le script échoue.

Pour une base de données, `PRE_BACKUP_CMD` reste préférable : un `mysqldump`
applicatif vaut mieux qu'un gel du système de fichiers.

### Une seule passe d'archivage

La version d'origine faisait `cp -r` vers un répertoire temporaire, puis `tar`
dessus, puis `rm -rf` : deux fois l'espace disque et deux fois les E/S pour le
même résultat. `tar -C "$src" -czf "$dest" .` suffit.

### L'image du conteneur n'est plus sauvegardée par défaut

`docker commit` + `docker save` archivait l'image entière à chaque cycle
(souvent plusieurs gigaoctets) alors qu'elle est reconstructible depuis le
registre ou le Dockerfile. Ce qui a de la valeur, c'est le volume.

Sont désormais conservés les volumes, le `docker inspect` complet et le tag de
l'image. `BACKUP_IMAGE=1` rétablit l'ancien comportement, avec compression :
l'archive `docker save` d'origine n'était même pas compressée.

### Le succès est mesuré, pas supposé

```bash
write_log "Sauvegarde terminée..."
if [ $? -eq 0 ] && ... ; then send_email "Rapport de sauvegarde"; fi
```

`$?` capturait le code retour de `write_log` - un `echo >>`, toujours nul. Aucun
retour de `docker save`, `tar` ou `cp` n'était vérifié. Le rapport annonçait un
succès même quand rien n'avait été sauvegardé.

Un compteur `FAILURES` alimente désormais un fichier `STATUS`, le sujet du
courriel et le code de sortie. `MAIL_WHEN=onerror` évite l'accoutumance au
rapport quotidien qui fait qu'on ne le lit plus.

### Une sauvegarde non restaurée est une hypothèse

`verify` contrôle chaque archive (`tar -tzf`) et les empreintes SHA256.
`restore` existe, arrête les conteneurs concernés, réextrait les volumes et les
redémarre - derrière `CONFIRM_RESTORE=RESTORE`.

Testez-le. Une sauvegarde dont le chemin de restauration n'a jamais été exécuté
n'est pas une sauvegarde.

### Chiffrement et copie hors-site

Des sauvegardes stockées sur la machine sauvegardée ne protègent ni d'un
rançongiciel, ni d'une panne disque, ni d'un vol. C'était le cas de la version
d'origine, et c'est le point de sécurité le plus important de cet outil.

`ENCRYPT=1` (GPG AES256, passphrase dans un fichier hors sauvegarde) et
`RSYNC_DEST` rendent la règle 3-2-1 atteignable. Les deux sont désactivés par
défaut : les activer sans destination valide donnerait une fausse assurance.

### Détails

`flock` empêche deux exécutions concurrentes de corrompre les archives et de
fausser la rotation. `umask 077` : les archives contiennent des données
applicatives. Le sujet du courriel est débarrassé de ses retours à la ligne,
qui injecteraient des en-têtes SMTP arbitraires.

`docker commit` refuse les tags en majuscules ; la version d'origine ne
normalisait le nom que dans la branche quotidienne, si bien que les sauvegardes
hebdomadaires et mensuelles échouaient sur un conteneur comportant une
majuscule. La normalisation est maintenant faite en un seul endroit - il n'y a
plus qu'un seul chemin de code.
