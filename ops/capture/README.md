# HeyMail Capture

Local/staging inbox for application development. It deliberately does not use
the production HeyMail SMTP delivery path.

## Start

Use a dedicated Compose project so the capture sandbox stays separate from the
main HeyMail development stack:

```bash
docker compose \
  -p heymail-capture \
  -f compose.capture.yaml \
  up -d
```

Default endpoints:

- SMTP: `127.0.0.1:1025`
- Inbox UI: `http://127.0.0.1:8025`

Symfony example:

```dotenv
MAILER_DSN=smtp://127.0.0.1:1025
```

## Network model

Mailpit itself is attached **only** to `heymail_capture_net`, which is a Docker
`internal: true` network. It therefore has no normal external route.

Because an internal Docker network is intentionally isolated from host network
interfaces, a small HAProxy ingress sidecar exposes only two fixed inbound
destinations:

- host `127.0.0.1:1025` -> `capture:1025`
- host `127.0.0.1:8025` -> `capture:8025`

The ingress sidecar has no dynamic forward-proxy configuration and cannot be
used by Mailpit as an arbitrary SMTP/HTTP egress proxy.

If another application runs in Docker and should send directly to Mailpit,
attach that application to the external network `heymail_capture_net` and use:

```dotenv
MAILER_DSN=smtp://capture:1025
```

## Security properties

- Mailpit is version-pinned and OCI-digest-pinned.
- HAProxy is version-pinned and OCI-digest-pinned.
- Mailpit's automatic version check is disabled.
- Mailpit is attached only to an `internal: true` network.
- Host SMTP/UI bindings are loopback-only.
- Mailpit's root filesystem is read-only.
- Mailpit's only writable filesystem is `/tmp`, backed by tmpfs.
- Linux capabilities are dropped from both containers.
- `no-new-privileges` is enabled on both containers.
- Mailpit's local Host allowlist is enabled.
- Captured mail is ephemeral and disappears when the capture container is
  recreated.

The integration gate proves that a container attached only to the Mailpit
internal network cannot open a TCP connection to a public Internet address.

For staging, keep SMTP private. Put any staging inbox UI behind the staging
reverse proxy and authentication layer.
