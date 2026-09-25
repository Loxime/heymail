# HeyMail Capture

Local inbox for application development. It deliberately does not use the
production HeyMail SMTP delivery path and Mailpit has no normal Internet egress.

## Universal CLI

Install once from a HeyMail checkout:

```bash
./scripts/install-heymail-capture.sh
```

The default installation is:

- binary: `~/.local/bin/heymail-capture`
- bundle: `~/.local/share/heymail-capture`

Make sure `~/.local/bin` is in `PATH`.

Commands:

```bash
heymail-capture up
heymail-capture status
heymail-capture open
heymail-capture dsn host
heymail-capture dsn docker
heymail-capture logs
heymail-capture down
```

Default endpoints:

- host SMTP: `smtp://127.0.0.1:1025`
- Docker SMTP: `smtp://capture:1025`
- inbox UI: `http://127.0.0.1:8025`

A host application can use:

```dotenv
MAILER_DSN=smtp://127.0.0.1:1025
```

For scripts and application setup, the CLI exposes the canonical values:

```bash
heymail-capture dsn host
# smtp://127.0.0.1:1025

heymail-capture dsn docker
# smtp://capture:1025
```

The capture inbox supports normal SMTP MIME messages, including multipart
text/HTML newsletters and attachments. The integration gate verifies all three
and checks Mailpit's rendered text/HTML preview endpoints.

## Inject into any Docker Compose project

From another project's root:

```bash
heymail-capture up
heymail-capture inject app
docker compose \
  -f compose.yaml \
  -f compose.heymail-capture.yaml \
  up -d
```

Replace `app` with the service that sends mail.

`inject` does not edit the project's existing Compose file or application
configuration. It creates only `compose.heymail-capture.yaml`, marked as managed
by HeyMail Capture. The override:

- sets `MAILER_DSN=smtp://capture:1025` on the selected service;
- attaches that service to the external `heymail_capture_net`;
- leaves every other service untouched.

Reverse it with:

```bash
heymail-capture eject
```

`eject` refuses to remove a file that does not carry the HeyMail Capture
ownership marker.

## Direct Compose usage

The repository-local sandbox can still be started without installing the CLI:

```bash
docker compose \
  -p heymail-capture \
  -f compose.capture.yaml \
  up -d
```

## Network model

Mailpit itself is attached **only** to `heymail_capture_net`, which is a Docker
`internal: true` network. It therefore has no normal external route.

A small HAProxy ingress sidecar exposes only two fixed inbound destinations:

- host `127.0.0.1:1025` -> `capture:1025`
- host `127.0.0.1:8025` -> `capture:8025`

The ingress sidecar has no dynamic forward-proxy configuration and cannot be
used by Mailpit as an arbitrary SMTP/HTTP egress proxy.

Docker applications explicitly injected by the CLI join the external network
`heymail_capture_net` and address Mailpit directly as `capture:1025`.

## Security properties

- Mailpit is version-pinned and OCI-digest-pinned.
- HAProxy is version-pinned and OCI-digest-pinned.
- Mailpit's automatic version check is disabled.
- Mailpit is attached only to an `internal: true` network.
- Host SMTP/UI bindings are loopback-only by default.
- The CLI checks default host port availability before first startup.
- Mailpit's root filesystem is read-only.
- Mailpit's only writable filesystem is `/tmp`, backed by tmpfs.
- Linux capabilities are dropped from both containers.
- `no-new-privileges` is enabled on both containers.
- Mailpit's local Host allowlist is enabled.
- Captured mail is ephemeral and disappears when the capture container is
  recreated.
- Project injection is explicit and reversible; existing project files are not
  silently modified.

`tests/integration/capture-mode.sh` proves the underlying sandbox has no TCP
Internet egress. `tests/integration/capture-cli.sh` proves install, startup,
project injection, external-network attachment and reversal with a disposable
Compose project.

For staging, keep SMTP private. Put any staging inbox UI behind the staging
reverse proxy and authentication layer.
