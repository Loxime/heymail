<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;

final readonly class DkimKeyMaterial
{
    public function __construct(
        public string $selector,
        public string $publicKey,
    ) {
        if (
            preg_match(
                '/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D',
                $this->selector,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid DKIM selector.',
            );
        }

        if (
            $this->publicKey === ''
            || base64_decode(
                $this->publicKey,
                true,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Invalid DKIM public key.',
            );
        }
    }

    public function recordName(
        string $domain,
    ): string {
        return sprintf(
            '%s._domainkey.%s',
            $this->selector,
            $domain,
        );
    }

    public function recordValue(): string
    {
        return sprintf(
            'v=DKIM1; k=rsa; p=%s',
            $this->publicKey,
        );
    }
}
