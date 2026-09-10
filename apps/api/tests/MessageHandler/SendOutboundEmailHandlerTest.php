<?php

declare(strict_types=1);

namespace App\Tests\MessageHandler;

use App\Entity\OutboundMessage;
use App\Entity\OutboundMessagePayload;
use App\Enum\OutboundMessageStatus;
use App\Mail\EmailAddress;
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundEmailPayloadCipher;
use App\Mail\OutboundMessageSubmitter;
use App\Message\SendOutboundEmail;
use App\MessageHandler\SendOutboundEmailHandler;
use Doctrine\ORM\EntityManagerInterface;
use Doctrine\ORM\EntityRepository;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;

final class SendOutboundEmailHandlerTest
    extends TestCase
{
    private string $keyFile;

    protected function setUp(): void
    {
        $path = tempnam(
            sys_get_temp_dir(),
            'heymail-handler-kek-',
        );

        self::assertIsString(
            $path,
        );

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

    public function testHandlerDecryptsSubmitsAndMarksMessageSubmitted(): void
    {
        [
            $outbound,
            $storedPayload,
        ] = $this->createOutboundWithPayload(
            'handler-submit',
        );

        $repository = $this->createMock(
            EntityRepository::class,
        );

        $repository
            ->expects(self::once())
            ->method('findOneBy')
            ->willReturn(
                $storedPayload,
            );

        $entityManager = $this->createMock(
            EntityManagerInterface::class,
        );

        $entityManager
            ->expects(self::once())
            ->method('find')
            ->with(
                OutboundMessage::class,
                42,
            )
            ->willReturn(
                $outbound,
            );

        $entityManager
            ->expects(self::once())
            ->method('getRepository')
            ->with(
                OutboundMessagePayload::class,
            )
            ->willReturn(
                $repository,
            );

        $entityManager
            ->expects(self::exactly(2))
            ->method('flush');

        $submitter = $this->createMock(
            OutboundMessageSubmitter::class,
        );

        $submitter
            ->expects(self::once())
            ->method('submit')
            ->with(
                42,
                self::callback(
                    static function (
                        mixed $payload,
                    ): bool {
                        self::assertInstanceOf(
                            OutboundEmailPayload::class,
                            $payload,
                        );

                        self::assertSame(
                            'Handler integration',
                            $payload->subject,
                        );

                        return true;
                    },
                ),
            );

        $handler = new SendOutboundEmailHandler(
            $entityManager,
            $this->cipher(),
            $submitter,
        );

        $handler(
            new SendOutboundEmail(42),
        );

        self::assertSame(
            OutboundMessageStatus::SUBMITTED,
            $outbound->getStatus(),
        );

        self::assertNotNull(
            $outbound->getReadyForSubmissionAt(),
        );

        self::assertNotNull(
            $outbound->getSubmittedAt(),
        );
    }

    public function testDuplicateSubmittedDeliveryIsNoOp(): void
    {
        $outbound = new OutboundMessage(
            'duplicate-handler-test',
        );

        $outbound->markReadyForSubmission();
        $outbound->markSubmitted();

        $entityManager = $this->createMock(
            EntityManagerInterface::class,
        );

        $entityManager
            ->method('find')
            ->willReturn(
                $outbound,
            );

        $entityManager
            ->expects(self::never())
            ->method('getRepository');

        $entityManager
            ->expects(self::never())
            ->method('flush');

        $submitter = $this->createMock(
            OutboundMessageSubmitter::class,
        );

        $submitter
            ->expects(self::never())
            ->method('submit');

        $handler = new SendOutboundEmailHandler(
            $entityManager,
            $this->cipher(),
            $submitter,
        );

        $handler(
            new SendOutboundEmail(42),
        );
    }

    public function testMissingEntityIsUnrecoverable(): void
    {
        $entityManager = $this->createStub(
            EntityManagerInterface::class,
        );

        $entityManager
            ->method('find')
            ->willReturn(null);

        $submitter = $this->createStub(
            OutboundMessageSubmitter::class,
        );

        $handler = new SendOutboundEmailHandler(
            $entityManager,
            $this->cipher(),
            $submitter,
        );

        $this->expectException(
            UnrecoverableMessageHandlingException::class,
        );

        $handler(
            new SendOutboundEmail(404),
        );
    }

    public function testMissingEncryptedPayloadIsUnrecoverable(): void
    {
        $outbound = new OutboundMessage(
            'missing-payload',
        );

        $repository = $this->createStub(
            EntityRepository::class,
        );

        $repository
            ->method('findOneBy')
            ->willReturn(null);

        $entityManager = $this->createMock(
            EntityManagerInterface::class,
        );

        $entityManager
            ->method('find')
            ->willReturn(
                $outbound,
            );

        $entityManager
            ->method('getRepository')
            ->willReturn(
                $repository,
            );

        $entityManager
            ->expects(self::never())
            ->method('flush');

        $submitter = $this->createMock(
            OutboundMessageSubmitter::class,
        );

        $submitter
            ->expects(self::never())
            ->method('submit');

        $handler = new SendOutboundEmailHandler(
            $entityManager,
            $this->cipher(),
            $submitter,
        );

        $this->expectException(
            UnrecoverableMessageHandlingException::class,
        );

        $handler(
            new SendOutboundEmail(42),
        );
    }

    /**
     * @return array{
     *     OutboundMessage,
     *     OutboundMessagePayload
     * }
     */
    private function createOutboundWithPayload(
        string $idempotencyKey,
    ): array {
        $outbound = new OutboundMessage(
            $idempotencyKey,
        );

        $encrypted = $this
            ->cipher()
            ->encrypt(
                $outbound
                    ->getIdempotencyKeyHash(),
                new OutboundEmailPayload(
                    from: new EmailAddress(
                        'sender@heymail.test',
                    ),
                    to: [
                        new EmailAddress(
                            'recipient@success.test',
                        ),
                    ],
                    subject: 'Handler integration',
                    textPart: 'Handler body',
                ),
            );

        return [
            $outbound,
            new OutboundMessagePayload(
                $outbound,
                $encrypted,
            ),
        ];
    }

    private function cipher(): OutboundEmailPayloadCipher
    {
        return new OutboundEmailPayloadCipher(
            $this->keyFile,
        );
    }
}
