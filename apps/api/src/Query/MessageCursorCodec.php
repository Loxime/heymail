<?php

declare(strict_types=1);

namespace App\Query;

use InvalidArgumentException;
use JsonException;

final readonly class MessageCursorCodec
{
    public function __construct(
        private string $secret,
    ) {
        if ($this->secret === '') {
            throw new InvalidArgumentException(
                'Message cursor secret cannot be empty.',
            );
        }
    }

    public function encode(int $lastMessageId): string
    {
        if ($lastMessageId < 1) {
            throw new InvalidArgumentException(
                'Cursor message identifier must be positive.',
            );
        }

        try {
            $payload = json_encode(
                [
                    'v' => 1,
                    'id' => $lastMessageId,
                ],
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException $exception) {
            throw new InvalidArgumentException(
                'Unable to encode message cursor.',
                0,
                $exception,
            );
        }

        $encodedPayload =
            self::base64UrlEncode(
                $payload,
            );

        $mac =
            hash_hmac(
                'sha256',
                $encodedPayload,
                $this->secret,
                true,
            );

        return $encodedPayload
            . '.'
            . self::base64UrlEncode(
                $mac,
            );
    }

    public function decode(string $cursor): int
    {
        if (
            $cursor === ''
            || strlen($cursor) > 512
        ) {
            throw new InvalidArgumentException(
                'Invalid message cursor.',
            );
        }

        $parts = explode(
            '.',
            $cursor,
            2,
        );

        if (count($parts) !== 2) {
            throw new InvalidArgumentException(
                'Invalid message cursor.',
            );
        }

        [
            $encodedPayload,
            $encodedMac,
        ] = $parts;

        $mac =
            self::base64UrlDecode(
                $encodedMac,
            );

        $expectedMac =
            hash_hmac(
                'sha256',
                $encodedPayload,
                $this->secret,
                true,
            );

        if (
            !hash_equals(
                $expectedMac,
                $mac,
            )
        ) {
            throw new InvalidArgumentException(
                'Invalid message cursor signature.',
            );
        }

        $payload =
            self::base64UrlDecode(
                $encodedPayload,
            );

        try {
            $decoded = json_decode(
                $payload,
                true,
                8,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException $exception) {
            throw new InvalidArgumentException(
                'Invalid message cursor payload.',
                0,
                $exception,
            );
        }

        if (
            !is_array($decoded)
            || ($decoded['v'] ?? null) !== 1
            || !isset($decoded['id'])
            || !is_int($decoded['id'])
            || $decoded['id'] < 1
        ) {
            throw new InvalidArgumentException(
                'Invalid message cursor payload.',
            );
        }

        return $decoded['id'];
    }

    private static function base64UrlEncode(
        string $value,
    ): string {
        return rtrim(
            strtr(
                base64_encode(
                    $value,
                ),
                '+/',
                '-_',
            ),
            '=',
        );
    }

    private static function base64UrlDecode(
        string $value,
    ): string {
        if (
            $value === ''
            || preg_match(
                '/^[A-Za-z0-9_-]+$/D',
                $value,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid message cursor encoding.',
            );
        }

        $padding =
            strlen($value) % 4;

        if ($padding !== 0) {
            $value .= str_repeat(
                '=',
                4 - $padding,
            );
        }

        $decoded =
            base64_decode(
                strtr(
                    $value,
                    '-_',
                    '+/',
                ),
                true,
            );

        if ($decoded === false) {
            throw new InvalidArgumentException(
                'Invalid message cursor encoding.',
            );
        }

        return $decoded;
    }
}
