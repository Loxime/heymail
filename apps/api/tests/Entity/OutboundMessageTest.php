<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class OutboundMessageTest extends TestCase
{
    public function testCreationHashesIdempotencyKey(): void
    {
        $message = new OutboundMessage(
            'request-123',
        );

        self::assertNull($message->getId());

        self::assertSame(
            hash('sha256', 'request-123'),
            $message->getIdempotencyKeyHash(),
        );

        self::assertSame(
            OutboundMessageStatus::QUEUED,
            $message->getStatus(),
        );

        self::assertNull(
            $message->getReadyForSubmissionAt(),
        );
    }

    public function testReadyTransitionIsIdempotent(): void
    {
        $message = new OutboundMessage(
            'request-ready',
        );

        $at = new DateTimeImmutable(
            '2026-09-06T15:00:00+00:00',
        );

        $message->markReadyForSubmission($at);
        $message->markReadyForSubmission();

        self::assertSame(
            OutboundMessageStatus::READY_FOR_SUBMISSION,
            $message->getStatus(),
        );

        self::assertSame(
            $at,
            $message->getReadyForSubmissionAt(),
        );
    }

    public function testEmptyIdempotencyKeyIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new OutboundMessage('   ');
    }
}
