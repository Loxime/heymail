# Étape 0001 — Validation de l'environnement de développement

## Objectif

Vérifier que la machine locale dispose d'une base suffisamment récente et cohérente pour construire le laboratoire Docker de HeyMail avant d'ajouter les premiers services.

## Machine de référence

Les informations suivantes ont été relevées le 5 septembre 2026 sur la machine de développement :

| Élément | Valeur |
|---|---|
| Système | Ubuntu 26.04 LTS (Resolute Raccoon) |
| Architecture | x86_64 |
| Noyau | Linux 7.0.0-30-generic |
| Docker Engine | 29.7.2 |
| Docker Compose | 5.4.0 |
| Storage driver | overlayfs |
| Cgroups | v2 |
| Git | 2.53.0 |
| OpenSSL | 3.5.5 |
| Partition `/` | 99 GiB, 62 GiB disponibles |
| Mémoire | 7.2 GiB, environ 3.2 GiB disponibles au relevé |
| Swap | 3.8 GiB |

## Analyse

### Docker

Docker Engine et Docker Compose sont présents et suffisamment récents pour le laboratoire prévu. L'utilisation de cgroups v2 permet de s'appuyer sur le modèle moderne de contrôle des ressources Linux. Le stockage `overlayfs` est adapté au fonctionnement standard des conteneurs Docker.

### Cryptographie

OpenSSL 3.5.5 fournit une base moderne pour les opérations TLS nécessaires aux futurs tests SMTP et HTTPS. Les secrets applicatifs ne devront cependant pas dépendre du seul stockage de certificats OpenSSL : une politique dédiée de secrets et de clés sera appliquée.

### Ressources

La machine dispose d'un espace disque confortable pour le développement. La mémoire disponible est suffisante pour commencer avec PostgreSQL, une API, Postfix, Rspamd et plusieurs faux serveurs MX, à condition de limiter explicitement les ressources et de surveiller l'utilisation lorsque les tests d'intégration seront parallélisés.

## Risques identifiés

- La machine est un environnement de développement : aucune hypothèse de sécurité de production ne doit être fondée sur son seul durcissement.
- Les conteneurs devront recevoir des limites et privilèges explicites au fur et à mesure de leur ajout.
- L'accès SMTP public restera désactivé pendant la phase laboratoire.

## Critères de validation

- Docker disponible : OK.
- Docker Compose disponible : OK.
- Git disponible : OK.
- OpenSSL disponible : OK.
- Architecture prise en charge : OK.
- Espace disque suffisant : OK.
- Mémoire suffisante pour commencer : OK.

## État

VALIDÉ pour le démarrage du squelette du projet.
