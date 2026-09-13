<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;
use RuntimeException;

final class BounceAddressCodec
{
    private string $domain;
    private string $key;

    public function __construct(
        string $bounceDomain,
        string $hmacKeyFile,
    ) {
        if (
            $bounceDomain === ''
            || str_contains(
                $bounceDomain,
                '@',
            )
            || filter_var(
                'probe@' . $bounceDomain,
                FILTER_VALIDATE_EMAIL,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Invalid HeyMail bounce domain.',
            );
        }

        $encodedKey =
            @file_get_contents(
                $hmacKeyFile,
            );

        if ($encodedKey === false) {
            throw new RuntimeException(
                'Unable to read bounce HMAC key.',
            );
        }

        $encodedKey = trim(
            $encodedKey,
        );

        if (
            preg_match(
                '/^[a-f0-9]{64}$/D',
                $encodedKey,
            ) !== 1
        ) {
            throw new RuntimeException(
                'Bounce HMAC key has an invalid format.',
            );
        }

        $key = hex2bin(
            $encodedKey,
        );

        if (!is_string($key)) {
            throw new RuntimeException(
                'Unable to decode bounce HMAC key.',
            );
        }

        $this->domain =
            strtolower(
                $bounceDomain,
            );

        $this->key = $key;
    }

    public function domain(): string
    {
        return $this->domain;
    }

    public function senderFor(
        int $outboundMessageId,
    ): string {
        if ($outboundMessageId < 1) {
            throw new InvalidArgumentException(
                'Outbound message identifier must be positive.',
            );
        }

        return sprintf(
            'bounce+%d+%s@%s',
            $outboundMessageId,
            $this->tokenFor(
                $outboundMessageId,
            ),
            $this->domain,
        );
    }

    public function tokenFor(
        int $outboundMessageId,
    ): string {
        if ($outboundMessageId < 1) {
            throw new InvalidArgumentException(
                'Outbound message identifier must be positive.',
            );
        }

        $payload =
            "heymail-bounce-v1\0"
            . $outboundMessageId
            . "\0"
            . $this->domain;

        return substr(
            hash_hmac(
                'sha256',
                $payload,
                $this->key,
            ),
            0,
            32,
        );
    }

    public function validates(
        int $outboundMessageId,
        string $token,
    ): bool {
        if (
            preg_match(
                '/^[a-f0-9]{32}$/D',
                $token,
            ) !== 1
        ) {
            return false;
        }

        return hash_equals(
            $this->tokenFor(
                $outboundMessageId,
            ),
            $token,
        );
    }
}
