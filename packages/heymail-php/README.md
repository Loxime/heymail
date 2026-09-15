# HeyMail PHP client

Minimal client for applications that send transactional messages through HeyMail.

```php
use HeyMail\HeyMailHub;

$hub = new HeyMailHub(
    baseUri: $_ENV['HEYMAIL_BASE_URI'],
    apiKey: $_ENV['HEYMAIL_API_KEY'],
    apiSecret: $_ENV['HEYMAIL_API_SECRET'],
    defaultFrom: 'errors@heymail.falchero.fr',
);

$hub
    ->message()
    ->to('maximefalchero@gmail.com')
    ->subject('Erreur production')
    ->text('Un utilisateur vient d’être déconnecté.')
    ->send();
```

Symfony service example:

```yaml
services:
    HeyMail\HeyMailHub:
        arguments:
            $baseUri: '%env(HEYMAIL_BASE_URI)%'
            $apiKey: '%env(HEYMAIL_API_KEY)%'
            $apiSecret: '%env(HEYMAIL_API_SECRET)%'
            $defaultFrom: '%env(HEYMAIL_DEFAULT_FROM)%'
```

A transport failure is intentionally **not automatically retried**: once the HTTP request has crossed the network boundary the submission outcome may be ambiguous. Reuse an explicit idempotency key if the caller needs to reconcile/replay a request safely.
