# Étape 0000 — Cadrage initial de HeyMail

## Objectif

Définir le périmètre du projet avant toute implémentation et empêcher qu'une décision de structure rende plus difficile l'isolation ou la protection des secrets par la suite.

## Périmètre initial

HeyMail doit fournir une infrastructure autonome d'envoi d'emails sortants ainsi qu'une application de supervision web, mobile et bureau.

Le projet n'implémente pas, dans son périmètre initial, un fournisseur complet de boîtes aux lettres IMAP/POP3.

## Principes retenus

- Développement local d'abord.
- Dockerisation des composants.
- Aucun service payant nécessaire au fonctionnement.
- Aucun envoi SMTP vers Internet pendant les premières phases.
- Tests unitaires, intégration, E2E, sécurité et scénarios de panne avant les essais publics.
- Principe du moindre privilège.
- Segmentation réseau entre services.
- Secrets hors Git.
- Clés DKIM séparées des applications.
- Contenus sensibles destinés à être chiffrés au repos.
- Journal de développement mis à jour à chaque étape.

## État

VALIDÉ — cadrage initial uniquement. Aucun composant fonctionnel n'est encore implémenté.
