<?php

declare(strict_types=1);

namespace App\Webhook;

use App\Entity\WebhookEndpoint;

final readonly class WebhookRegistration
{
    public function __construct(
        public WebhookEndpoint $endpoint,
        public string $secret,
    ) {
    }
}
