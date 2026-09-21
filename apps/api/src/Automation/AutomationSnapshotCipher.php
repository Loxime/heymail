<?php

declare(strict_types=1);

namespace App\Automation;

use JsonException;
use RuntimeException;
use SodiumException;

final class AutomationSnapshotCipher
{
    public const string ALGORITHM =
        'xchacha20poly1305-ietf';

    public const int KEY_VERSION = 1;

    private string $kek;

    public function __construct(
        string $payloadKekFile,
    ) {
        $encoded =
            @file_get_contents(
                $payloadKekFile,
            );

        if ($encoded === false) {
            throw new RuntimeException(
                'Unable to read automation snapshot KEK.',
            );
        }

        try {
            $key = sodium_base642bin(
                trim($encoded),
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            );
        } catch (SodiumException $exception) {
            throw new RuntimeException(
                'Automation snapshot KEK is not valid Base64.',
                0,
                $exception,
            );
        }

        if (
            strlen($key)
            !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES
        ) {
            throw new RuntimeException(
                'Automation snapshot KEK has an invalid size.',
            );
        }

        $this->kek = $key;
    }

    /**
     * @param array<string, mixed> $snapshot
     *
     * @return array{
     *     ciphertext:string,
     *     nonce:string,
     *     wrappedDek:string,
     *     wrapNonce:string,
     *     algorithm:string,
     *     keyVersion:int
     * }
     */
    public function encrypt(
        int $workspaceId,
        int $jobId,
        array $snapshot,
    ): array {
        $context =
            self::context(
                $workspaceId,
                $jobId,
            );

        try {
            $plain = json_encode(
                $snapshot,
                JSON_THROW_ON_ERROR
                | JSON_UNESCAPED_SLASHES
                | JSON_UNESCAPED_UNICODE,
            );
        } catch (JsonException $exception) {
            throw new RuntimeException(
                'Automation snapshot cannot be encoded.',
                0,
                $exception,
            );
        }

        $dek = random_bytes(
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES,
        );

        try {
            $nonce = random_bytes(
                SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES,
            );

            $ciphertext =
                sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                    $plain,
                    'heymail:automation-payload:v1:'
                    . $context,
                    $nonce,
                    $dek,
                );

            $wrapNonce = random_bytes(
                SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES,
            );

            $wrappedDek =
                sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                    $dek,
                    'heymail:automation-dek:v1:'
                    . $context,
                    $wrapNonce,
                    $this->kek,
                );
        } finally {
            sodium_memzero(
                $dek,
            );
        }

        return [
            'ciphertext'
                => self::encode(
                    $ciphertext,
                ),
            'nonce'
                => self::encode(
                    $nonce,
                ),
            'wrappedDek'
                => self::encode(
                    $wrappedDek,
                ),
            'wrapNonce'
                => self::encode(
                    $wrapNonce,
                ),
            'algorithm'
                => self::ALGORITHM,
            'keyVersion'
                => self::KEY_VERSION,
        ];
    }

    /**
     * @param array{
     *     ciphertext:string,
     *     nonce:string,
     *     wrappedDek:string,
     *     wrapNonce:string,
     *     algorithm:string,
     *     keyVersion:int
     * } $encrypted
     *
     * @return array<string, mixed>
     */
    public function decrypt(
        int $workspaceId,
        int $jobId,
        array $encrypted,
    ): array {
        if (
            $encrypted['algorithm']
                !== self::ALGORITHM
            || $encrypted['keyVersion']
                !== self::KEY_VERSION
        ) {
            throw new RuntimeException(
                'Unsupported automation snapshot encryption metadata.',
            );
        }

        $context =
            self::context(
                $workspaceId,
                $jobId,
            );

        $dek =
            sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                self::decode(
                    $encrypted['wrappedDek'],
                ),
                'heymail:automation-dek:v1:'
                . $context,
                self::decode(
                    $encrypted['wrapNonce'],
                ),
                $this->kek,
            );

        if ($dek === false) {
            throw new RuntimeException(
                'Unable to unwrap automation snapshot DEK.',
            );
        }

        try {
            $plain =
                sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                    self::decode(
                        $encrypted['ciphertext'],
                    ),
                    'heymail:automation-payload:v1:'
                    . $context,
                    self::decode(
                        $encrypted['nonce'],
                    ),
                    $dek,
                );
        } finally {
            sodium_memzero(
                $dek,
            );
        }

        if ($plain === false) {
            throw new RuntimeException(
                'Automation snapshot authentication failed.',
            );
        }

        try {
            $decoded = json_decode(
                $plain,
                true,
                128,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException $exception) {
            throw new RuntimeException(
                'Automation snapshot plaintext is invalid.',
                0,
                $exception,
            );
        }

        if (
            !is_array($decoded)
            || array_is_list($decoded)
        ) {
            throw new RuntimeException(
                'Automation snapshot plaintext must be an object.',
            );
        }

        return $decoded;
    }

    private static function context(
        int $workspaceId,
        int $jobId,
    ): string {
        if (
            $workspaceId < 1
            || $jobId < 1
        ) {
            throw new RuntimeException(
                'Invalid automation encryption context.',
            );
        }

        return hash(
            'sha256',
            sprintf(
                'heymail:automation-snapshot:v1:%d:%d',
                $workspaceId,
                $jobId,
            ),
        );
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
                'Automation snapshot contains invalid Base64.',
                0,
                $exception,
            );
        }
    }
}
