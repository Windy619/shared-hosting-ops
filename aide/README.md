# aide

Contrôle d'intégrité [AIDE](https://aide.github.io/) avec un cycle de vie
explicite de la base de référence.

```bash
aide.sh init      # crée la base de référence (une seule fois)
aide.sh check     # contrôle d'intégrité, sans jamais modifier la base
aide.sh update    # accepte l'état courant comme nouvelle référence
aide.sh status    # état de la base, empreinte, dernier rapport
```

## Installation

```bash
cp aide-report.conf.example /etc/aide-report.conf
chmod 600 /etc/aide-report.conf
install -m 750 aide.sh /usr/local/bin/

aide.sh init                    # puis conserver l'empreinte affichée
```

```cron
0 4 * * *  /usr/local/bin/aide.sh check
```

`update` n'est **jamais** appelé par cron.

---

## Décisions

### `check` ne met jamais la base à jour

C'est la correction centrale. La version d'origine enchaînait, dans le même
cron :

```bash
aide --check >> rapport.txt
aide --update > /dev/null
cp -p aide.db.new.gz aide.db.gz
```

Une modification malveillante était donc signalée **une seule fois**, noyée dans
un rapport quotidien, puis validée comme état normal par la nouvelle base. Le
lendemain, tout paraissait conforme.

C'est un anti-pattern documenté des HIDS : la mise à jour de la référence doit
être une décision humaine, prise après lecture du rapport. `update` exige
`CONFIRM_UPDATE=UPDATE` et archive la base précédente avant de la remplacer.

### La falsification de la base est détectée

La base de référence vit sur la machine qu'elle surveille. Un attaquant root
peut la régénérer et rendre AIDE définitivement aveugle - c'est la limite
structurelle de l'outil sur un serveur unique, et on ne peut pas l'éliminer
depuis la machine elle-même.

On peut en revanche la **rendre visible**. L'empreinte SHA256 de la base est
enregistrée à chaque `update` et vérifiée à chaque `check`. Une divergence
déclenche le statut `COMPROMISSION POSSIBLE`, qui prime sur tout autre résultat.

L'empreinte figure aussi dans **chaque courriel** : la boîte mail devient la
copie hors-machine, et il devient possible de comparer avec les rapports
précédents. `USE_CHATTR=1` ajoute `chattr +i` entre deux mises à jour.

### Le verdict vient du code de sortie, pas du texte

```bash
if [ `cat rapport.txt | grep "AIDE found differences" | wc -l` != 0 ]
```

Cette condition ne distinguait pas « aucune différence » d'« AIDE a échoué » :
dans les deux cas, aucune correspondance, donc le même courriel rassurant.

Le [manuel](https://linux.die.net/man/1/aide) définit pourtant un code précis :

```
1 × (nouveaux) + 2 × (supprimés) + 4 × (modifiés)     résultat d'analyse
14 à 19                                                erreur d'exécution
```

`classify_aide_rc` et `describe_aide_rc` l'exploitent, et six tests couvrent les
combinaisons - dont celui qui vérifie qu'une erreur d'exécution n'est jamais
classée comme un système conforme.

### Seul un extrait circule par courriel

Un rapport AIDE complet liste l'arborescence et les empreintes du serveur :
c'est une cartographie utile à un attaquant, et elle transitait en clair par
SMTP. Le courriel contient désormais un résumé et les `MAX_REPORT_LINES`
premières lignes ; le rapport intégral reste sur le serveur, en 600.

`mail -a` a également disparu : l'option désigne une pièce jointe avec
`bsd-mailx` mais un **en-tête supplémentaire** avec `s-nail` ou `heirloom`. Le
comportement changeait silencieusement selon la distribution. L'envoi passe par
`sendmail` avec des en-têtes MIME explicites, avec repli sur `mail`.

### Le premier lancement n'invente plus de résultat

L'ancien script exécutait `aide_report` même quand la branche `--init` venait de
s'exécuter : le fichier de rapport n'existait pas, `cat` échouait, et un
courriel « aucune modification trouvée » partait quand même - sans qu'aucun
contrôle n'ait eu lieu.

`init` est désormais explicite, et `check` refuse de s'exécuter sans base.

Dans le même esprit, `"Check Done"` était ajouté au rapport **après** son envoi :
le fichier archivé et le fichier envoyé différaient. Le rapport est maintenant
clos avant expédition.

### Sans argument, le script sort en erreur

L'ancienne crontab appelait `aide.sh` tout court. Avec une interface à
sous-commandes, afficher l'aide et sortir en 0 transformerait ce cron en tâche
silencieusement inopérante - exactement le défaut corrigé partout ailleurs. Le
script sort donc en erreur, et cron envoie la sortie.

### Détails

Dates ISO 8601 pour que la rotation des rapports et des bases archivées suive
l'ordre chronologique. `flock` contre les exécutions concurrentes, qui
corrompraient la base. `umask 077` et contrôle explicite des droits root - AIDE
doit lire l'intégralité du système de fichiers. Plus aucune adresse ni chemin en
dur : tout vient de `/etc/aide-report.conf`.
