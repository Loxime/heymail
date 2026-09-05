# HeyMail

HeyMail is a self-hosted outbound email infrastructure project designed to be developed, tested and secured locally before any SMTP traffic is allowed to reach the public Internet.

## Current state

This archive represents the project **before the first structure commit**.
No mail server, API, database or user interface has been implemented yet.

The repository currently establishes:

- the monorepo layout;
- the future trust boundaries for Docker networks;
- a strict `.gitignore` policy;
- a safe `.env.example`;
- the secret-storage policy;
- the development journal structure;
- the initial security documentation;
- a pre-commit secret sanity check.

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
