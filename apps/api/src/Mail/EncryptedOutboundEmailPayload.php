<?php

declare(strict_types=1);

namespace App\Mail;

final readonly class EncryptedOutboundEmailPayload
{
    public function __construct(
        public string $ciphertext,
        public string $nonce,
        public string $wrappedDek,
        public string $wrapNonce,
        public string $algorithm,
        public int $keyVersion,
    ) {
    }
}
