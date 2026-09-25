# HeyMail PHP client

Small client for applications that send through HeyMail with the same
application-facing API in local development and production.

## Recommended integration: environment-only mode switch

Application code stays identical:

```php
use HeyMail\HeyMailHub;

$hub = HeyMailHub::fromEnvironment();

$hub
    ->message()
    ->to('user@example.com')
    ->subject('Welcome')
    ->text('Plain-text fallback')
    ->html('<h1>Welcome</h1>')
    ->send();
```

Local development uses HeyMail Capture:

```dotenv
HEYMAIL_MODE=capture
HEYMAIL_CAPTURE_DSN=smtp://127.0.0.1:1025
HEYMAIL_DEFAULT_FROM=dev@heymail.test
```

For an application running in Docker on the injected capture network:

```dotenv
HEYMAIL_CAPTURE_DSN=smtp://capture:1025
```

Production uses the real HeyMail HTTPS API:

```dotenv
HEYMAIL_MODE=api
HEYMAIL_BASE_URI=https://api.heymail.falchero.fr
HEYMAIL_DEFAULT_FROM=noreply@heymail.falchero.fr
HEYMAIL_API_KEY_FILE=/run/secrets/heymail_api_key
HEYMAIL_API_SECRET_FILE=/run/secrets/heymail_api_secret
```

Direct `HEYMAIL_API_KEY` and `HEYMAIL_API_SECRET` variables are also supported
when file-backed secrets are not available. File-backed values take precedence.

`HEYMAIL_CA_FILE` may be set when a private CA is required.

Capture mode deliberately accepts only loopback SMTP endpoints or the Docker
service name `capture`; it cannot be configured to send directly to an arbitrary
Internet SMTP server. It returns `status=captured`, `replayed=false`, and no
production API `messageId`.

Production/API mode keeps the normal HeyMail idempotency contract. A transport
failure is intentionally **not automatically retried**: once the HTTPS request
has crossed the network boundary the submission outcome may be ambiguous.
Reuse an explicit idempotency key when the caller needs to reconcile/replay a
request safely.

## Explicit API construction

Existing integrations remain valid:

```php
$hub = new HeyMailHub(
    baseUri: $_ENV['HEYMAIL_BASE_URI'],
    apiKey: $_ENV['HEYMAIL_API_KEY'],
    apiSecret: $_ENV['HEYMAIL_API_SECRET'],
    defaultFrom: 'noreply@heymail.falchero.fr',
);
```

Symfony service example:

```yaml
services:
    HeyMail\HeyMailHub:
        factory: ['HeyMail\HeyMailHub', 'fromEnvironment']
```
