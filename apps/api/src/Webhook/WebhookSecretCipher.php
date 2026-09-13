<?php

declare(strict_types=1);

namespace App\Webhook;

use RuntimeException;
use SodiumException;

final class WebhookSecretCipher
{
    public const string ALGORITHM =
        'xchacha20poly1305-ietf';

    public const int KEY_VERSION = 1;

    private string $key;

    public function __construct(
        string $webhookKekFile,
    ) {
        $encoded =
            @file_get_contents(
                $webhookKekFile,
            );

        if ($encoded === false) {
            throw new RuntimeException(
                'Unable to read webhook KEK.',
            );
        }

        try {
            $key = sodium_base642bin(
                trim($encoded),
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            );
        } catch (SodiumException $exception) {
            throw new RuntimeException(
                'Webhook KEK is not valid Base64.',
                0,
                $exception,
            );
        }

        if (
            strlen($key)
            !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES
        ) {
            throw new RuntimeException(
                'Webhook KEK has an invalid size.',
            );
        }

        $this->key = $key;
    }

    public function encrypt(
        string $context,
        string $secret,
    ): EncryptedWebhookSecret {
        self::assertContext(
            $context,
        );

        if (
            $secret === ''
            || strlen($secret) > 255
        ) {
            throw new RuntimeException(
                'Invalid webhook secret.',
            );
        }

        $nonce = random_bytes(
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES,
        );

        $ciphertext =
            sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                $secret,
                self::aad(
                    $context,
                ),
                $nonce,
                $this->key,
            );

        return new EncryptedWebhookSecret(
            ciphertext: self::encode(
                $ciphertext,
            ),
            nonce: self::encode(
                $nonce,
            ),
            algorithm: self::ALGORITHM,
            keyVersion: self::KEY_VERSION,
        );
    }

    public function decrypt(
        string $context,
        EncryptedWebhookSecret $encrypted,
    ): string {
        self::assertContext(
            $context,
        );

        if (
            $encrypted->algorithm
            !== self::ALGORITHM
            || $encrypted->keyVersion
            !== self::KEY_VERSION
        ) {
            throw new RuntimeException(
                'Unsupported webhook secret encryption metadata.',
            );
        }

        try {
            $plaintext =
                sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                    self::decode(
                        $encrypted->ciphertext,
                    ),
                    self::aad(
                        $context,
                    ),
                    self::decode(
                        $encrypted->nonce,
                    ),
                    $this->key,
                );
        } catch (SodiumException $exception) {
            throw new RuntimeException(
                'Webhook secret cannot be decrypted.',
                0,
                $exception,
            );
        }

        if ($plaintext === false) {
            throw new RuntimeException(
                'Webhook secret authentication failed.',
            );
        }

        return $plaintext;
    }

    private static function aad(
        string $context,
    ): string {
        return 'heymail:webhook-secret:v1:'
            . $context;
    }

    private static function assertContext(
        string $context,
    ): void {
        if (
            preg_match(
                '/^wh_[a-f0-9]{32}$/D',
                $context,
            ) !== 1
        ) {
            throw new RuntimeException(
                'Invalid webhook encryption context.',
            );
        }
    }

    private static function encode(
        string $value,
    ): string {
        return sodium_bin2base64(
            $value,
            SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
        );
    }

    private static function decode(
        string $value,
    ): string {
        try {
            return sodium_base642bin(
                $value,
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            );
        } catch (SodiumException $exception) {
            throw new RuntimeException(
                'Invalid webhook encryption encoding.',
                0,
                $exception,
            );
        }
    }
}
