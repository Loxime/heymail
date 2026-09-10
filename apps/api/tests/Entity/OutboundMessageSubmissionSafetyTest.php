<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageStatus;
use LogicException;
use PHPUnit\Framework\TestCase;

final class OutboundMessageSubmissionSafetyTest extends TestCase
{
    public function testSubmissionStateMachine(): void
    {
        $message =
            new OutboundMessage(
                'submission-state-machine',
            );

        self::assertSame(
            OutboundMessageStatus::QUEUED,
            $message->getStatus(),
        );

        $message->markReadyForSubmission();

        self::assertSame(
            OutboundMessageStatus::READY_FOR_SUBMISSION,
            $message->getStatus(),
        );

        $message->markSubmitting();

        self::assertSame(
            OutboundMessageStatus::SUBMITTING,
            $message->getStatus(),
        );

        $message->markSubmitted();

        self::assertSame(
            OutboundMessageStatus::SUBMITTED,
            $message->getStatus(),
        );

        self::assertNotNull(
            $message->getReadyForSubmissionAt(),
        );

        self::assertNotNull(
            $message->getSubmittedAt(),
        );
    }

    public function testSubmittingCanBecomeUncertain(): void
    {
        $message =
            new OutboundMessage(
                'submission-uncertain',
            );

        $message->markReadyForSubmission();
        $message->markSubmitting();
        $message->markSubmissionUncertain();

        self::assertSame(
            OutboundMessageStatus::SUBMISSION_UNCERTAIN,
            $message->getStatus(),
        );

        /*
         * A final uncertain state cannot accidentally return to READY.
         */
        $message->markReadyForSubmission();

        self::assertSame(
            OutboundMessageStatus::SUBMISSION_UNCERTAIN,
            $message->getStatus(),
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
