<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Entity\OutboundMessage;
use App\Mail\EmailAddress;
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundEmailPayloadCipher;
use App\Mail\OutboundMessagePayloadCryptor;
use PHPUnit\Framework\TestCase;
use RuntimeException;

final class OutboundMessagePayloadCryptorTest
    extends TestCase
{
    private string $keyFile;

    protected function setUp(): void
    {
        $path = tempnam(
            sys_get_temp_dir(),
            'heymail-workspace-payload-',
        );

        self::assertIsString(
            $path,
        );

        $this->keyFile = $path;

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

    public function testCurrentPayloadCannotMoveAcrossWorkspaces(): void
    {
        $cryptor = $this->cryptor();

        $messageA = new OutboundMessage(
            'shared-key',
            11,
        );

        $messageB = new OutboundMessage(
            'shared-key',
            12,
        );

        $encrypted = $cryptor->encrypt(
            $messageA,
            self::payload(),
        );

        self::assertEquals(
            self::payload(),
            $cryptor->decrypt(
                $messageA,
                $encrypted,
            ),
        );

        $this->expectException(
            RuntimeException::class,
        );

        $cryptor->decrypt(
            $messageB,
            $encrypted,
        );
    }

    public function testLegacyPayloadContextStillDecrypts(): void
    {
        $message = new OutboundMessage(
            'legacy-key',
            11,
        );

        $cipher = $this->cipher();

        $legacyEncrypted = $cipher->encrypt(
            $message
                ->getIdempotencyKeyHash(),
            self::payload(),
        );

        self::assertEquals(
            self::payload(),
            $this
                ->cryptor()
                ->decrypt(
                    $message,
                    $legacyEncrypted,
                ),
        );
    }

    private function cipher(): OutboundEmailPayloadCipher
    {
        return new OutboundEmailPayloadCipher(
            $this->keyFile,
        );
    }

    private function cryptor(): OutboundMessagePayloadCryptor
    {
        return new OutboundMessagePayloadCryptor(
            $this->cipher(),
        );
    }

    private static function payload(): OutboundEmailPayload
    {
        return new OutboundEmailPayload(
            from: new EmailAddress(
                'sender@heymail.test',
            ),
            to: [
                new EmailAddress(
                    'recipient@success.test',
                ),
            ],
            subject: 'Workspace payload',
            textPart: 'Secret payload.',
        );
    }
}
