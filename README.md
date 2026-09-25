# HeyMail

HeyMail is a self-hosted outbound email infrastructure project designed to be developed, tested and secured locally before any SMTP traffic is allowed to reach the public Internet.

## Current state

HeyMail now contains the self-hosted mail platform used by the project:

- authenticated HTTPS transactional send API with mandatory idempotency;
- PostgreSQL-backed encrypted payload persistence and immutable delivery events;
- Postfix + Rspamd + DKIM outbound delivery;
- workspaces, scoped API credentials, senders, templates, contacts, campaigns,
  automations, tracking and suppressions;
- authenticated bounce/DSN handling;
- explicit inbound aliases with forwarding and SRS, without mailbox storage or
  catch-all relay;
- HeyMail Capture, a local Mailpit-based inbox with no normal Internet egress;
- a PHP client that switches between local capture and the production HeyMail
  API through environment configuration only.

The production v1.1 release remains isolated from v1.2 development until the
v1.2 release gates and deployment procedure are completed.

## Planned components

```text
apps/api/                    Symfony API
apps/web/                    Vue web client
infrastructure/postfix/      SMTP/MTA configuration
infrastructure/rspamd/       DKIM and mail filtering/policy
docker/                      Shared Docker assets
secrets/                     LOCAL secrets only — ignored by Git
tests/unit/                  Unit tests
tests/integration/           Integration tests
tests/e2e/                   End-to-end tests
tests/security/              Security/adversarial tests
docs/architecture/           Architecture decisions and diagrams
docs/security/               Threat model and security rules
docs/journal/                Step-by-step development journal
scripts/                     Development and verification scripts
```

## First local setup

```bash
cp .env.example .env
mkdir -p secrets
```

Do not put real secrets in `.env`. Secret values will progressively be stored as local files under `secrets/` and mounted into containers using Docker secrets.

## Verify that secrets are not staged

Before the first commit:

```bash
./scripts/pre-commit-check.sh
```

Then inspect Git explicitly:

```bash
git status --short
git check-ignore -v .env
```

The second command must show that `.env` is ignored.

## Internet SMTP policy

During the laboratory phases, public SMTP egress will remain disabled. Tests will use isolated fake MX servers on `smtp_lab_net` until the security, integration and failure suites are validated.
