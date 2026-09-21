<?php

declare(strict_types=1);

namespace App\Suppression;

use InvalidArgumentException;
use JsonException;
use SodiumException;

final readonly class UnsubscribeTokenCodec
{
    private const string PREFIX = 'u1.';
    private const string AAD = 'heymail:unsubscribe:v1';
    private const int MAX_TOKEN_BYTES = 1024;

    private string $key;
    private string $publicOrigin;

    public function __construct(
        string $secret,
        string $publicOrigin,
    ) {
        if ($secret === '') {
            throw new InvalidArgumentException(
                'Unsubscribe secret cannot be empty.',
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
                'Unsubscribe public origin must be HTTPS.',
            );
        }

        $this->key = hash(
            'sha256',
            self::AAD . "\0" . $secret,
            true,
        );

        $this->publicOrigin = $origin;
    }

    public function url(
        int $workspaceId,
        ?int $contactListId,
        string $email,
    ): string {
        return sprintf(
            '%s/unsubscribe/%s',
            $this->publicOrigin,
            $this->encode(
                $workspaceId,
                $contactListId,
                $email,
            ),
        );
    }

    public function encode(
        int $workspaceId,
        ?int $contactListId,
        string $email,
    ): string {
        if ($workspaceId < 1) {
            throw new InvalidArgumentException(
                'Invalid unsubscribe workspace.',
            );
        }

        if (
            $contactListId !== null
            && $contactListId < 1
        ) {
            throw new InvalidArgumentException(
                'Invalid unsubscribe list.',
            );
        }

        $email = trim(
            $email,
        );

        if (
            filter_var(
                $email,
                FILTER_VALIDATE_EMAIL,
            ) === false
            || strlen($email) > 254
        ) {
            throw new InvalidArgumentException(
                'Invalid unsubscribe email.',
            );
        }

        try {
            $plaintext = json_encode(
                [
                    'v' => 1,
                    'w' => $workspaceId,
                    'l' => $contactListId,
                    'e' => strtolower(
                        $email,
                    ),
                ],
                JSON_THROW_ON_ERROR
                | JSON_UNESCAPED_SLASHES,
            );
        } catch (JsonException $exception) {
            throw new InvalidArgumentException(
                'Unable to encode unsubscribe token.',
                0,
                $exception,
            );
        }

        /*
         * Campaign submission idempotency requires the same logical
         * recipient to produce the same encrypted payload on replay.
         *
         * Derive a 192-bit nonce from the authenticated plaintext with
         * the unsubscribe key. Different plaintexts therefore receive
         * different nonces, while an exact replay is deterministic.
         */
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

    /**
     * @return array{
     *     workspaceId:int,
     *     contactListId:int|null,
     *     email:string
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
                'Invalid unsubscribe token.',
            );
        }

        try {
            $binary = sodium_base642bin(
                substr(
                    $token,
                    strlen(
                        self::PREFIX,
                    ),
                ),
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            );
        } catch (SodiumException $exception) {
            throw new InvalidArgumentException(
                'Invalid unsubscribe token.',
                0,
                $exception,
            );
        }

        $nonceBytes =
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES;

        if (
            strlen($binary)
            <= $nonceBytes
        ) {
            throw new InvalidArgumentException(
                'Invalid unsubscribe token.',
            );
        }

        $plaintext =
            sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                substr(
                    $binary,
                    $nonceBytes,
                ),
                self::AAD,
                substr(
                    $binary,
                    0,
                    $nonceBytes,
                ),
                $this->key,
            );

        if ($plaintext === false) {
            throw new InvalidArgumentException(
                'Invalid unsubscribe token.',
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
                'Invalid unsubscribe token.',
                0,
                $exception,
            );
        }

        if (
            !is_array($data)
            || array_is_list($data)
            || array_keys($data)
                !== ['v', 'w', 'l', 'e']
            || $data['v'] !== 1
            || !is_int($data['w'])
            || $data['w'] < 1
            || (
                $data['l'] !== null
                && (
                    !is_int($data['l'])
                    || $data['l'] < 1
                )
            )
            || !is_string($data['e'])
            || filter_var(
                $data['e'],
                FILTER_VALIDATE_EMAIL,
            ) === false
            || strlen($data['e']) > 254
        ) {
            throw new InvalidArgumentException(
                'Invalid unsubscribe token.',
            );
        }

        return [
            'workspaceId' => $data['w'],
            'contactListId' => $data['l'],
            'email' => strtolower(
                $data['e'],
            ),
        ];
    }
}
