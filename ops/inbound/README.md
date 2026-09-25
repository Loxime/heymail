# HeyMail inbound forwarding

Sprint 1 adds a single public SMTP ingress for two responsibilities:

- authenticated HeyMail DSN recipients on `HEYMAIL_BOUNCE_DOMAIN`;
- explicit forwarding aliases on `HEYMAIL_INBOUND_DOMAIN`.

No mailbox is stored by HeyMail. Normal inbound messages are forwarded to the
configured external address and only exist transiently in the Postfix queue.

## Alias secret

Production aliases live in:

```text
secrets/prod/inbound_aliases
```

Format:

```text
reply@heymail.falchero.fr destination@example.net
contact@heymail.falchero.fr destination@example.net
```

Rules:

- one explicit source and one destination per line;
- no catch-all;
- source must belong to `HEYMAIL_INBOUND_DOMAIN`;
- destination must not point back to the same inbound domain.

## SRS

Forwarded messages use PostSRSd so the envelope sender is rewritten before the
message leaves HeyMail. A dedicated `HEYMAIL_SRS_DOMAIN` is used for rewritten
return paths. This prevents ordinary SPF forwarding failures and lets delivery
failures return through HeyMail without conflicting with normal inbound aliases.

The SRS signing secret is:

```text
secrets/prod/inbound_srs_secret
```

It must contain exactly 64 lowercase hexadecimal characters and must never be
committed.

## Public SMTP

`inbound-ingress` becomes the only service publishing host port 25.

The historical `dsn-loopback-proxy` remains available only on
`127.0.0.1:3025` for diagnostics; it no longer owns public port 25.
