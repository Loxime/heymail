<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\EmailAddress;
use App\Mail\EncryptedOutboundEmailPayload;
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundEmailPayloadCipher;
use PHPUnit\Framework\TestCase;
use RuntimeException;

final class OutboundEmailPayloadCipherTest extends TestCase
{
    private string $keyFile;

    protected function setUp(): void
    {
        $path = tempnam(
            sys_get_temp_dir(),
            'heymail-kek-',
        );

        self::assertIsString($path);

        $this->keyFile = $path;

        $key = random_bytes(
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES,
        );

        file_put_contents(
            $this->keyFile,
            sodium_bin2base64(
                $key,
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            ),
        );
    }

    protected function tearDown(): void
    {
        if (isset($this->keyFile)) {
            @unlink(
                $this->keyFile,
            );
        }
    }

    public function testPayloadRoundTrip(): void
    {
        $cipher = new OutboundEmailPayloadCipher(
            $this->keyFile,
        );

        $payload = self::payload();

        $context = hash(
            'sha256',
            'idempotency-key',
        );

        $encrypted = $cipher->encrypt(
            $context,
            $payload,
        );

        self::assertNotSame(
            json_encode(
                $payload->toArray(),
            ),
            $encrypted->ciphertext,
        );

        self::assertEquals(
            $payload,
            $cipher->decrypt(
                $context,
                $encrypted,
            ),
        );
    }

    public function testTamperingFailsClosed(): void
    {
        $cipher = new OutboundEmailPayloadCipher(
            $this->keyFile,
        );

        $context = hash(
            'sha256',
            'tamper-test',
        );

        $encrypted = $cipher->encrypt(
            $context,
            self::payload(),
        );

        $tampered = new EncryptedOutboundEmailPayload(
            ciphertext: $encrypted->ciphertext . 'A',
            nonce: $encrypted->nonce,
            wrappedDek: $encrypted->wrappedDek,
            wrapNonce: $encrypted->wrapNonce,
            algorithm: $encrypted->algorithm,
            keyVersion: $encrypted->keyVersion,
        );

        $this->expectException(
            RuntimeException::class,
        );

        $cipher->decrypt(
            $context,
            $tampered,
        );
    }

    public function testPayloadCannotBeMovedToAnotherMessage(): void
    {
        $cipher = new OutboundEmailPayloadCipher(
            $this->keyFile,
        );

        $encrypted = $cipher->encrypt(
            hash(
                'sha256',
                'message-a',
            ),
            self::payload(),
        );

        $this->expectException(
            RuntimeException::class,
        );

        $cipher->decrypt(
            hash(
                'sha256',
                'message-b',
            ),
            $encrypted,
        );
    }

    private static function payload(): OutboundEmailPayload
    {
        return new OutboundEmailPayload(
            from: new EmailAddress(
                'sender@heymail.test',
                'HeyMail',
            ),
            to: [
                new EmailAddress(
                    'recipient@success.test',
                ),
            ],
            subject: 'Encrypted email',
            textPart: 'Secret body marker.',
            htmlPart: '<p>Secret HTML.</p>',
        );
    }
}
