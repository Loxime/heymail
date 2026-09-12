<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use PHPUnit\Framework\TestCase;

final class OutboundMessageEventTest extends TestCase
{
    public function testCreationRecordsQueuedEvent(): void
    {
        $message = new OutboundMessage(
            'events-created',
        );

        $events = $message->getEvents();

        self::assertCount(
            1,
            $events,
        );

        self::assertSame(
            OutboundMessageStatus::QUEUED,
            $events[0]->getType(),
        );

        self::assertSame(
            $message->getCreatedAt(),
            $events[0]->getOccurredAt(),
        );

        self::assertSame(
            $message,
            $events[0]->getOutboundMessage(),
        );
    }

    public function testNormalSubmissionRecordsOrderedTimeline(): void
    {
        $message = new OutboundMessage(
            'events-normal',
        );

        $ready =
            new DateTimeImmutable(
                '2026-09-12T20:00:01+00:00',
            );

        $submitting =
            new DateTimeImmutable(
                '2026-09-12T20:00:02+00:00',
            );

        $submitted =
            new DateTimeImmutable(
                '2026-09-12T20:00:03+00:00',
            );

        $message->markReadyForSubmission(
            $ready,
        );

        $message->markSubmitting(
            $submitting,
        );

        $message->markSubmitted(
            $submitted,
        );

        $events = $message->getEvents();

        self::assertSame(
            [
                OutboundMessageStatus::QUEUED,
                OutboundMessageStatus::READY_FOR_SUBMISSION,
                OutboundMessageStatus::SUBMITTING,
                OutboundMessageStatus::SUBMITTED,
            ],
            array_map(
                static fn ($event) =>
                    $event->getType(),
                $events,
            ),
        );

        self::assertSame(
            $ready,
            $events[1]->getOccurredAt(),
        );

        self::assertSame(
            $submitting,
            $events[2]->getOccurredAt(),
        );

        self::assertSame(
            $submitted,
            $events[3]->getOccurredAt(),
        );
    }

    public function testIdempotentTransitionsDoNotDuplicateEvents(): void
    {
        $message = new OutboundMessage(
            'events-idempotent',
        );

        $message->markReadyForSubmission();
        $message->markReadyForSubmission();

        $message->markSubmitting();
        $message->markSubmitting();

        $message->markSubmitted();
        $message->markSubmitted();

        self::assertCount(
            4,
            $message->getEvents(),
        );
    }

    public function testUncertainSubmissionRecordsTerminalEvent(): void
    {
        $message = new OutboundMessage(
            'events-uncertain',
        );

        $message->markReadyForSubmission();
        $message->markSubmitting();

        $uncertainAt =
            new DateTimeImmutable(
                '2026-09-12T20:10:00+00:00',
            );

        $message->markSubmissionUncertain(
            $uncertainAt,
        );

        $message->markSubmissionUncertain();

        $events = $message->getEvents();

        self::assertSame(
            [
                OutboundMessageStatus::QUEUED,
                OutboundMessageStatus::READY_FOR_SUBMISSION,
                OutboundMessageStatus::SUBMITTING,
                OutboundMessageStatus::SUBMISSION_UNCERTAIN,
            ],
            array_map(
                static fn ($event) =>
                    $event->getType(),
                $events,
            ),
        );

        self::assertSame(
            $uncertainAt,
            $events[3]->getOccurredAt(),
        );
    }
}
