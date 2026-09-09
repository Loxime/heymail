<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use InvalidArgumentException;
use LogicException;
use PHPUnit\Framework\TestCase;

final class OutboundMessageTest extends TestCase
{
    public function testCreationHashesIdempotencyKey(): void
    {
        $message = new OutboundMessage(
            'request-123',
        );

        self::assertNull(
            $message->getId(),
        );

        self::assertSame(
            hash(
                'sha256',
                'request-123',
            ),
            $message->getIdempotencyKeyHash(),
        );

        self::assertSame(
            OutboundMessageStatus::QUEUED,
            $message->getStatus(),
        );

        self::assertNull(
            $message->getReadyForSubmissionAt(),
        );

        self::assertNull(
            $message->getSubmittedAt(),
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

        $message->markReadyForSubmission(
            $at,
        );

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

    public function testSubmittedTransitionIsIdempotent(): void
    {
        $message = new OutboundMessage(
            'request-submitted',
        );

        $message->markReadyForSubmission();

        $at = new DateTimeImmutable(
            '2026-09-09T17:30:00+00:00',
        );

        $message->markSubmitted(
            $at,
        );

        $message->markSubmitted();

        self::assertSame(
            OutboundMessageStatus::SUBMITTED,
            $message->getStatus(),
        );

        self::assertSame(
            $at,
            $message->getSubmittedAt(),
        );

        $message->markReadyForSubmission();

        self::assertSame(
            OutboundMessageStatus::SUBMITTED,
            $message->getStatus(),
        );
    }

    public function testCannotSubmitBeforeReady(): void
    {
        $message = new OutboundMessage(
            'request-invalid-transition',
        );

        $this->expectException(
            LogicException::class,
        );

        $message->markSubmitted();
    }

    public function testEmptyIdempotencyKeyIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new OutboundMessage('   ');
    }
}
