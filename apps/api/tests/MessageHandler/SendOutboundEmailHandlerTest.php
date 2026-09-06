<?php

declare(strict_types=1);

namespace App\Tests\MessageHandler;

use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageStatus;
use App\Message\SendOutboundEmail;
use App\MessageHandler\SendOutboundEmailHandler;
use Doctrine\ORM\EntityManagerInterface;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;

final class SendOutboundEmailHandlerTest extends TestCase
{
    public function testHandlerMarksMessageReady(): void
    {
        $outbound = new OutboundMessage(
            'handler-test',
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
            ->willReturn($outbound);

        $entityManager
            ->expects(self::once())
            ->method('flush');

        $handler = new SendOutboundEmailHandler(
            $entityManager,
        );

        $handler(
            new SendOutboundEmail(42),
        );

        self::assertSame(
            OutboundMessageStatus::READY_FOR_SUBMISSION,
            $outbound->getStatus(),
        );

        self::assertNotNull(
            $outbound->getReadyForSubmissionAt(),
        );
    }

    public function testDuplicateDeliveryIsNoOp(): void
    {
        $outbound = new OutboundMessage(
            'duplicate-handler-test',
        );

        $outbound->markReadyForSubmission();

        $entityManager = $this->createMock(
            EntityManagerInterface::class,
        );

        $entityManager
            ->method('find')
            ->willReturn($outbound);

        $entityManager
            ->expects(self::never())
            ->method('flush');

        $handler = new SendOutboundEmailHandler(
            $entityManager,
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

        $handler = new SendOutboundEmailHandler(
            $entityManager,
        );

        $this->expectException(
            UnrecoverableMessageHandlingException::class,
        );

        $handler(
            new SendOutboundEmail(404),
        );
    }
}
