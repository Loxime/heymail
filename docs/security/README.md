# Security baseline

HeyMail est conçu comme une infrastructure sensible.

## Règles initiales

- Aucun secret réel dans Git.
- Aucun secret réel dans `.env.example`.
- Aucun accès Internet SMTP pendant le laboratoire initial.
- Aucun conteneur ne reçoit un réseau, un volume, une capability ou un secret sans justification.
- Les corps de mails ne doivent pas être inscrits en clair dans les logs.
- Une application compromise ne doit pas donner automatiquement accès à la clé DKIM.
- Les limites de débit et mécanismes de révocation seront obligatoires avant les essais publics.
- Toute prévisualisation HTML de mail devra être considérée comme du contenu hostile.

## Modèle de menace

Le modèle de menace détaillé sera créé avant l'implémentation de l'API et couvrira notamment : vol de BDD, compromission de client API, open relay, injections d'en-têtes, XSS via email, SSRF, exfiltration de secrets, compromission de conteneur et abus de capacité d'envoi.
