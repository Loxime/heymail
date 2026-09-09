<?php

declare(strict_types=1);

namespace App\Mail;

use RuntimeException;
use SodiumException;

final class OutboundEmailPayloadCipher
{
    public const string ALGORITHM = 'xchacha20poly1305-ietf';
    public const int KEY_VERSION = 1;

    private string $kek;

    public function __construct(
        string $payloadKekFile,
    ) {
        $encodedKey = @file_get_contents(
            $payloadKekFile,
        );

        if ($encodedKey === false) {
            throw new RuntimeException(
                'Unable to read outbound payload KEK.',
            );
        }

        try {
            $key = sodium_base642bin(
                trim($encodedKey),
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            );
        } catch (SodiumException $exception) {
            throw new RuntimeException(
                'Outbound payload KEK is not valid Base64.',
                0,
                $exception,
            );
        }

        if (
            strlen($key)
            !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES
        ) {
            throw new RuntimeException(
                'Outbound payload KEK has an invalid size.',
            );
        }

        $this->kek = $key;
    }

    public function encrypt(
        string $context,
        OutboundEmailPayload $payload,
    ): EncryptedOutboundEmailPayload {
        self::assertContext($context);

        $plaintext = json_encode(
            $payload->toArray(),
            JSON_THROW_ON_ERROR
            | JSON_UNESCAPED_SLASHES
            | JSON_UNESCAPED_UNICODE,
        );

        $dek = random_bytes(
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES,
        );

        try {
            $nonce = random_bytes(
                SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES,
            );

            $ciphertext =
                sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                    $plaintext,
                    self::payloadAad($context),
                    $nonce,
                    $dek,
                );

            $wrapNonce = random_bytes(
                SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES,
            );

            $wrappedDek =
                sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                    $dek,
                    self::dekAad($context),
                    $wrapNonce,
                    $this->kek,
                );
        } finally {
            sodium_memzero($dek);
        }

        return new EncryptedOutboundEmailPayload(
            ciphertext: self::encode(
                $ciphertext,
            ),
            nonce: self::encode(
                $nonce,
            ),
            wrappedDek: self::encode(
                $wrappedDek,
            ),
            wrapNonce: self::encode(
                $wrapNonce,
            ),
            algorithm: self::ALGORITHM,
            keyVersion: self::KEY_VERSION,
        );
    }

    public function decrypt(
        string $context,
        EncryptedOutboundEmailPayload $encrypted,
    ): OutboundEmailPayload {
        self::assertContext($context);

        if (
            $encrypted->algorithm !== self::ALGORITHM
            || $encrypted->keyVersion !== self::KEY_VERSION
        ) {
            throw new RuntimeException(
                'Unsupported outbound payload encryption metadata.',
            );
        }

        $wrappedDek = self::decode(
            $encrypted->wrappedDek,
        );

        $wrapNonce = self::decode(
            $encrypted->wrapNonce,
        );

        $dek =
            sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                $wrappedDek,
                self::dekAad($context),
                $wrapNonce,
                $this->kek,
            );

        if ($dek === false) {
            throw new RuntimeException(
                'Unable to unwrap outbound payload DEK.',
            );
        }

        try {
            $plaintext =
                sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                    self::decode(
                        $encrypted->ciphertext,
                    ),
                    self::payloadAad($context),
                    self::decode(
                        $encrypted->nonce,
                    ),
                    $dek,
                );

            if ($plaintext === false) {
                throw new RuntimeException(
                    'Unable to decrypt outbound payload.',
                );
            }
        } finally {
            sodium_memzero($dek);
        }

        $decoded = json_decode(
            $plaintext,
            true,
            512,
            JSON_THROW_ON_ERROR,
        );

        if (!is_array($decoded)) {
            throw new RuntimeException(
                'Decrypted outbound payload is invalid.',
            );
        }

        return OutboundEmailPayload::fromArray(
            $decoded,
        );
    }

    private static function assertContext(
        string $context,
    ): void {
        if (
            preg_match(
                '/^[a-f0-9]{64}$/D',
                $context,
            ) !== 1
        ) {
            throw new RuntimeException(
                'Invalid outbound payload encryption context.',
            );
        }
    }

    private static function payloadAad(
        string $context,
    ): string {
        return 'heymail:payload:v1:' . $context;
    }

    private static function dekAad(
        string $context,
    ): string {
        return 'heymail:payload-dek:v1:' . $context;
    }

    private static function encode(
        string $binary,
    ): string {
        return sodium_bin2base64(
            $binary,
            SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
        );
    }

    private static function decode(
        string $encoded,
    ): string {
        try {
            return sodium_base642bin(
                $encoded,
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            );
        } catch (SodiumException $exception) {
            throw new RuntimeException(
                'Encrypted payload contains invalid Base64.',
                0,
                $exception,
            );
        }
    }
}
