<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageEventType;
use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use LogicException;
use PHPUnit\Framework\TestCase;

final class OutboundMessageDeliveryEventTest extends TestCase
{
    public function testSubmittedMessageRecordsRecipientFeedback(): void
    {
        $message =
            new OutboundMessage(
                'delivery-feedback',
            );

        $message->markReadyForSubmission();
        $message->markSubmitting();
        $message->markSubmitted();

        $recipientHash =
            hash(
                'sha256',
                'user@example.test',
            );

        $message->recordDeliveryFeedback(
            type: OutboundMessageEventType::TEMPFAIL,
            recipientHash: $recipientHash,
            smtpStatus: '4.1.1',
            detail: 'Temporary recipient failure',
            sourceEventId: hash(
                'sha256',
                'tempfail-event',
            ),
        );

        $message->recordDeliveryFeedback(
            type: OutboundMessageEventType::DELIVERED,
            recipientHash: $recipientHash,
            smtpStatus: '2.0.0',
            detail: 'Message accepted',
            sourceEventId: hash(
                'sha256',
                'delivered-event',
            ),
            recipientDomain:
                'example.test',
        );

        self::assertSame(
            OutboundMessageStatus::SUBMITTED,
            $message->getStatus(),
        );

        $events =
            $message->getEvents();

        self::assertSame(
            OutboundMessageEventType::TEMPFAIL,
            $events[4]->getType(),
        );

        self::assertSame(
            OutboundMessageEventType::DELIVERED,
            $events[5]->getType(),
        );

        self::assertSame(
            $recipientHash,
            $events[5]->getRecipientHash(),
        );

        self::assertSame(
            'example.test',
            $events[5]->getRecipientDomain(),
        );

        self::assertSame(
            '2.0.0',
            $events[5]->getSmtpStatus(),
        );
    }

    public function testDuplicateSourceEventIsIdempotent(): void
    {
        $message =
            new OutboundMessage(
                'delivery-idempotent',
            );

        $message->markReadyForSubmission();
        $message->markSubmitting();
        $message->markSubmitted();

        $source =
            hash(
                'sha256',
                'same-postfix-line',
            );

        $arguments = [
            OutboundMessageEventType::DELIVERED,
            hash(
                'sha256',
                'user@example.test',
            ),
            '2.0.0',
            'Accepted',
            $source,
        ];

        $message->recordDeliveryFeedback(
            ...$arguments,
        );

        $message->recordDeliveryFeedback(
            ...$arguments,
        );

        self::assertCount(
            5,
            $message->getEvents(),
        );
    }

    public function testMtaEvidenceReconcilesUncertainSubmission(): void
    {
        $message =
            new OutboundMessage(
                'delivery-reconcile',
            );

        $message->markReadyForSubmission();
        $message->markSubmitting();
        $message->markSubmissionUncertain();

        $at =
            new DateTimeImmutable(
                '2026-09-12T22:30:00+00:00',
            );

        $message->recordDeliveryFeedback(
            type: OutboundMessageEventType::BOUNCED,
            recipientHash: hash(
                'sha256',
                'user@example.test',
            ),
            smtpStatus: '5.1.1',
            detail: 'Recipient rejected',
            sourceEventId: hash(
                'sha256',
                'bounce-proof',
            ),
            at: $at,
        );

        self::assertSame(
            OutboundMessageStatus::SUBMITTED,
            $message->getStatus(),
        );

        self::assertSame(
            $at,
            $message->getSubmittedAt(),
        );

        $events =
            $message->getEvents();

        self::assertSame(
            OutboundMessageEventType::SUBMITTED,
            $events[4]->getType(),
        );

        self::assertSame(
            OutboundMessageEventType::BOUNCED,
            $events[5]->getType(),
        );
    }

    public function testQueuedMessageRejectsDeliveryFeedback(): void
    {
        $message =
            new OutboundMessage(
                'delivery-too-early',
            );

        $this->expectException(
            LogicException::class,
        );

        $message->recordDeliveryFeedback(
            type: OutboundMessageEventType::DELIVERED,
            recipientHash: hash(
                'sha256',
                'user@example.test',
            ),
            smtpStatus: '2.0.0',
            detail: 'Accepted',
            sourceEventId: hash(
                'sha256',
                'invalid-early-feedback',
            ),
        );
    }
}
