<?php

declare(strict_types=1);

namespace App\Webhook;

final readonly class EncryptedWebhookSecret
{
    public function __construct(
        public string $ciphertext,
        public string $nonce,
        public string $algorithm,
        public int $keyVersion,
    ) {
    }
}
