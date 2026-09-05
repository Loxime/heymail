# Architecture

Ce répertoire accueillera les décisions d'architecture (ADR), les diagrammes, les frontières de confiance et les flux réseau de HeyMail.

## Frontières réseau prévues

- `frontend_net` : exposition contrôlée des interfaces applicatives.
- `data_net` : communications avec les données persistantes, sans accès Internet direct.
- `mail_net` : échanges entre workers applicatifs et le MTA.
- `filter_net` : échanges MTA ↔ moteur de politique/signature.
- `smtp_lab_net` : réseau fermé utilisé pour simuler des serveurs MX pendant les tests.
