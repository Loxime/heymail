# Local secrets directory

This directory is reserved for **local secret files** consumed by Docker secrets or by explicitly authorised development tooling.

Examples that may exist here later:

```text
postgres_password
application_kek
dkim_private_key
api_bootstrap_secret
```

Everything in this directory is ignored by Git except this README.

Rules:

1. Never commit a real secret.
2. Never copy a secret into `.env.example`.
3. Never print secrets in CI or application logs.
4. Use restrictive filesystem permissions when secret files are created.
5. Rotate a secret immediately if it is accidentally exposed.
