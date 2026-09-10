<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use DateTimeZone;
use LogicException;
use PHPUnit\Framework\TestCase;

final class OutboundMessageSubmissionSafetyTest extends TestCase
{
    public function testSubmissionStateMachineRecordsTimestamps(): void
    {
        $message =
            new OutboundMessage(
                'submission-state-machine',
            );

        $readyAt =
            new DateTimeImmutable(
                '2026-09-10T18:00:00+00:00',
                new DateTimeZone('UTC'),
            );

        $submittingAt =
            new DateTimeImmutable(
                '2026-09-10T18:00:01+00:00',
                new DateTimeZone('UTC'),
            );

        $submittedAt =
            new DateTimeImmutable(
                '2026-09-10T18:00:02+00:00',
                new DateTimeZone('UTC'),
            );

        self::assertSame(
            OutboundMessageStatus::QUEUED,
            $message->getStatus(),
        );

        self::assertNull(
            $message->getReadyForSubmissionAt(),
        );

        self::assertNull(
            $message->getSubmittingAt(),
        );

        self::assertNull(
            $message->getSubmissionUncertainAt(),
        );

        self::assertNull(
            $message->getSubmittedAt(),
        );

        $message->markReadyForSubmission(
            $readyAt,
        );

        $message->markSubmitting(
            $submittingAt,
        );

        $message->markSubmitted(
            $submittedAt,
        );

        self::assertSame(
            OutboundMessageStatus::SUBMITTED,
            $message->getStatus(),
        );

        self::assertSame(
            $readyAt,
            $message->getReadyForSubmissionAt(),
        );

        self::assertSame(
            $submittingAt,
            $message->getSubmittingAt(),
        );

        self::assertNull(
            $message->getSubmissionUncertainAt(),
        );

        self::assertSame(
            $submittedAt,
            $message->getSubmittedAt(),
        );
    }

    public function testUncertainSubmissionRecordsTimestamp(): void
    {
        $message =
            new OutboundMessage(
                'submission-uncertain',
            );

        $uncertainAt =
            new DateTimeImmutable(
                '2026-09-10T18:01:00+00:00',
                new DateTimeZone('UTC'),
            );

        $message->markReadyForSubmission();
        $message->markSubmitting();

        self::assertNotNull(
            $message->getSubmittingAt(),
        );

        $message->markSubmissionUncertain(
            $uncertainAt,
        );

        self::assertSame(
            OutboundMessageStatus::SUBMISSION_UNCERTAIN,
            $message->getStatus(),
        );

        self::assertSame(
            $uncertainAt,
            $message->getSubmissionUncertainAt(),
        );

        self::assertNull(
            $message->getSubmittedAt(),
        );
    }

    public function testRepeatedSubmittingDoesNotReplaceTimestamp(): void
    {
        $message =
            new OutboundMessage(
                'repeated-submitting',
            );

        $first =
            new DateTimeImmutable(
                '2026-09-10T18:02:00+00:00',
            );

        $second =
            new DateTimeImmutable(
                '2026-09-10T18:03:00+00:00',
            );

        $message->markReadyForSubmission();
        $message->markSubmitting($first);
        $message->markSubmitting($second);

        self::assertSame(
            $first,
            $message->getSubmittingAt(),
        );
    }

    public function testRepeatedUncertainDoesNotReplaceTimestamp(): void
    {
        $message =
            new OutboundMessage(
                'repeated-uncertain',
            );

        $first =
            new DateTimeImmutable(
                '2026-09-10T18:04:00+00:00',
            );

        $second =
            new DateTimeImmutable(
                '2026-09-10T18:05:00+00:00',
            );

        $message->markReadyForSubmission();
        $message->markSubmitting();

        $message->markSubmissionUncertain($first);
        $message->markSubmissionUncertain($second);

        self::assertSame(
            $first,
            $message->getSubmissionUncertainAt(),
        );
    }

    public function testQueuedMessageCannotBecomeUncertainDirectly(): void
    {
        $message =
            new OutboundMessage(
                'invalid-uncertain-transition',
            );

        $this->expectException(
            LogicException::class,
        );

        $message->markSubmissionUncertain();
    }

    public function testQueuedMessageCannotStartSubmissionDirectly(): void
    {
        $message =
            new OutboundMessage(
                'invalid-submitting-transition',
            );

        $this->expectException(
            LogicException::class,
        );

        $message->markSubmitting();
    }
}
