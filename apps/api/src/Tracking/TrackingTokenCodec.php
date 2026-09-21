<?php

declare(strict_types=1);

namespace App\Tracking;

use InvalidArgumentException;
use JsonException;
use SodiumException;

final readonly class TrackingTokenCodec
{
    private const string PREFIX = 't1.';
    private const string AAD = 'heymail:tracking:v1';
    private const int MAX_TOKEN_BYTES = 4096;
    private const int MAX_DESTINATION_BYTES = 2048;

    private string $key;
    private string $publicOrigin;

    public function __construct(
        string $secret,
        string $publicOrigin,
    ) {
        if ($secret === '') {
            throw new InvalidArgumentException(
                'Tracking secret cannot be empty.',
            );
        }

        $origin = rtrim(
            $publicOrigin,
            '/',
        );

        if (
            filter_var(
                $origin,
                FILTER_VALIDATE_URL,
            ) === false
            || !str_starts_with(
                strtolower($origin),
                'https://',
            )
        ) {
            throw new InvalidArgumentException(
                'Tracking public origin must be HTTPS.',
            );
        }

        $this->key = hash(
            'sha256',
            self::AAD . "\0" . $secret,
            true,
        );
        $this->publicOrigin = $origin;
    }

    public function openUrl(
        int $campaignId,
        int $recipientIndex,
    ): string {
        return sprintf(
            '%s/track/open/%s',
            $this->publicOrigin,
            $this->encode(
                $campaignId,
                $recipientIndex,
                'opened',
                null,
            ),
        );
    }

    public function clickUrl(
        int $campaignId,
        int $recipientIndex,
        string $destination,
    ): string {
        $destination = self::destination(
            $destination,
        );

        return sprintf(
            '%s/track/click/%s',
            $this->publicOrigin,
            $this->encode(
                $campaignId,
                $recipientIndex,
                'clicked',
                $destination,
            ),
        );
    }

    /**
     * @return array{
     *     campaignId:int,
     *     recipientIndex:int,
     *     eventType:'opened'|'clicked',
     *     destination:string|null
     * }
     */
    public function decode(
        string $token,
    ): array {
        if (
            strlen($token) > self::MAX_TOKEN_BYTES
            || !str_starts_with(
                $token,
                self::PREFIX,
            )
        ) {
            throw new InvalidArgumentException(
                'Invalid tracking token.',
            );
        }

        try {
            $binary = sodium_base642bin(
                substr(
                    $token,
                    strlen(self::PREFIX),
                ),
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            );
        } catch (SodiumException $exception) {
            throw new InvalidArgumentException(
                'Invalid tracking token.',
                0,
                $exception,
            );
        }

        $nonceBytes =
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES;

        if (strlen($binary) <= $nonceBytes) {
            throw new InvalidArgumentException(
                'Invalid tracking token.',
            );
        }

        $plaintext =
            sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                substr($binary, $nonceBytes),
                self::AAD,
                substr($binary, 0, $nonceBytes),
                $this->key,
            );

        if ($plaintext === false) {
            throw new InvalidArgumentException(
                'Invalid tracking token.',
            );
        }

        try {
            $data = json_decode(
                $plaintext,
                true,
                8,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException $exception) {
            throw new InvalidArgumentException(
                'Invalid tracking token.',
                0,
                $exception,
            );
        }

        if (
            !is_array($data)
            || array_is_list($data)
            || array_keys($data) !== ['v', 'c', 'r', 'k', 'u']
            || $data['v'] !== 1
            || !is_int($data['c'])
            || $data['c'] < 1
            || !is_int($data['r'])
            || $data['r'] < 0
            || !is_string($data['k'])
            || !in_array(
                $data['k'],
                ['opened', 'clicked'],
                true,
            )
        ) {
            throw new InvalidArgumentException(
                'Invalid tracking token.',
            );
        }

        if ($data['k'] === 'opened') {
            if ($data['u'] !== null) {
                throw new InvalidArgumentException(
                    'Invalid tracking token.',
                );
            }
            $destination = null;
        } else {
            if (!is_string($data['u'])) {
                throw new InvalidArgumentException(
                    'Invalid tracking token.',
                );
            }
            $destination = self::destination(
                $data['u'],
            );
        }

        return [
            'campaignId' => $data['c'],
            'recipientIndex' => $data['r'],
            'eventType' => $data['k'],
            'destination' => $destination,
        ];
    }

    private function encode(
        int $campaignId,
        int $recipientIndex,
        string $eventType,
        ?string $destination,
    ): string {
        if (
            $campaignId < 1
            || $recipientIndex < 0
            || !in_array(
                $eventType,
                ['opened', 'clicked'],
                true,
            )
            || ($eventType === 'opened' && $destination !== null)
            || ($eventType === 'clicked' && $destination === null)
        ) {
            throw new InvalidArgumentException(
                'Invalid tracking token data.',
            );
        }

        try {
            $plaintext = json_encode(
                [
                    'v' => 1,
                    'c' => $campaignId,
                    'r' => $recipientIndex,
                    'k' => $eventType,
                    'u' => $destination,
                ],
                JSON_THROW_ON_ERROR
                | JSON_UNESCAPED_SLASHES,
            );
        } catch (JsonException $exception) {
            throw new InvalidArgumentException(
                'Unable to encode tracking token.',
                0,
                $exception,
            );
        }

        $nonce = substr(
            hash_hmac(
                'sha256',
                "nonce\0" . $plaintext,
                $this->key,
                true,
            ),
            0,
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES,
        );

        $ciphertext =
            sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                $plaintext,
                self::AAD,
                $nonce,
                $this->key,
            );

        return self::PREFIX
            . sodium_bin2base64(
                $nonce . $ciphertext,
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            );
    }

    private static function destination(
        string $value,
    ): string {
        if (
            $value === ''
            || strlen($value) > self::MAX_DESTINATION_BYTES
            || preg_match(
                '/[\x00-\x20\x7F]/',
                $value,
            ) === 1
            || filter_var(
                $value,
                FILTER_VALIDATE_URL,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Invalid tracking destination.',
            );
        }

        $parts = parse_url($value);

        if (
            !is_array($parts)
            || strtolower(
                (string) ($parts['scheme'] ?? ''),
            ) !== 'https'
            || !is_string($parts['host'] ?? null)
            || $parts['host'] === ''
            || isset($parts['user'])
            || isset($parts['pass'])
        ) {
            throw new InvalidArgumentException(
                'Tracking destination must be an HTTPS URL without userinfo.',
            );
        }

        return $value;
    }
}
