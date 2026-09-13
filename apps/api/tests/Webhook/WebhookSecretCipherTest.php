<?php

declare(strict_types=1);

namespace App\Tests\Webhook;

use App\Webhook\WebhookSecretCipher;
use PHPUnit\Framework\TestCase;
use RuntimeException;

final class WebhookSecretCipherTest extends TestCase
{
    private string $keyFile;

    protected function setUp(): void
    {
        $this->keyFile =
            tempnam(
                sys_get_temp_dir(),
                'heymail-webhook-key-',
            );

        self::assertIsString(
            $this->keyFile,
        );

        file_put_contents(
            $this->keyFile,
            sodium_bin2base64(
                random_bytes(
                    SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES,
                ),
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            ),
        );
    }

    protected function tearDown(): void
    {
        @unlink(
            $this->keyFile,
        );
    }

    public function testEncryptsAndDecryptsSecret(): void
    {
        $cipher =
            new WebhookSecretCipher(
                $this->keyFile,
            );

        $context =
            'wh_'
            . str_repeat(
                'a',
                32,
            );

        $secret =
            'whsec_super-secret-value';

        $encrypted =
            $cipher->encrypt(
                $context,
                $secret,
            );

        self::assertStringNotContainsString(
            $secret,
            $encrypted->ciphertext,
        );

        self::assertSame(
            $secret,
            $cipher->decrypt(
                $context,
                $encrypted,
            ),
        );
    }

    public function testWrongContextFailsAuthentication(): void
    {
        $cipher =
            new WebhookSecretCipher(
                $this->keyFile,
            );

        $encrypted =
            $cipher->encrypt(
                'wh_'
                . str_repeat(
                    'a',
                    32,
                ),
                'whsec_value',
            );

        $this->expectException(
            RuntimeException::class,
        );

        $cipher->decrypt(
            'wh_'
            . str_repeat(
                'b',
                32,
            ),
            $encrypted,
        );
    }
}
