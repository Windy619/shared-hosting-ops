# Recettes de déploiement

Une recette de déploiement par techno. Chaque entrée est un miroir de ce qu'on
dépose dans le projet cible : son README dit quels fichiers copier, et où.

| Techno | État | Points d'entrée |
|---|---|---|
| [`laravel/`](laravel/) | en service | pipeline GitLab, Makefile en SSH direct |
| `php/` | à écrire | - |
| `python/` | à écrire | - |
| `java/` | à écrire | - |
| `bash/` | à écrire | - |

Les outils qui s'installent sur un serveur, et non dans un projet, restent hors
de ce dossier : [`docker-backup/`](../docker-backup/) et [`aide/`](../aide/).

## Ajouter une techno

Un dossier par techno, et dans son README une table des fichiers à copier avec
leur destination. Rien d'autre n'est imposé : une recette Python n'a aucune
raison de ressembler à une recette Laravel.
