<?php

declare(strict_types=1);

namespace App\Webhook;

final readonly class WebhookRequest
{
    public function __construct(
        public string $body,
        public string $timestamp,
        public string $signature,
    ) {
    }
}
