<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\OutboundMessageEventType;
use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\Common\Collections\ArrayCollection;
use Doctrine\Common\Collections\Collection;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use InvalidArgumentException;
use LogicException;

#[ORM\Entity]
#[ORM\Table(name: 'outbound_message')]
#[ORM\UniqueConstraint(
    name: 'uniq_outbound_message_idempotency_hash',
    columns: ['idempotency_key_hash'],
)]
#[ORM\Index(
    name: 'idx_outbound_message_status_list',
    columns: [
        'status',
        'id',
    ],
)]
#[ORM\Index(
    name: 'idx_outbound_message_created_list',
    columns: [
        'created_at',
        'id',
    ],
)]
final class OutboundMessage
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    // @phpstan-ignore property.unusedType
    private ?int $id = null;

    #[ORM\Column(
        name: 'idempotency_key_hash',
        type: Types::STRING,
        length: 64,
    )]
    private string $idempotencyKeyHash;

    #[ORM\Column(
        type: Types::STRING,
        length: 32,
        enumType: OutboundMessageStatus::class,
    )]
    private OutboundMessageStatus $status;

    #[ORM\Column(type: Types::DATETIME_IMMUTABLE)]
    private DateTimeImmutable $createdAt;

    #[ORM\Column(
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $readyForSubmissionAt = null;

    #[ORM\Column(
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $submittingAt = null;

    #[ORM\Column(
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $submissionUncertainAt = null;

    #[ORM\Column(
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $submittedAt = null;

    /**
     * @var Collection<int, OutboundMessageEvent>
     */
    #[ORM\OneToMany(
        mappedBy: 'outboundMessage',
        targetEntity: OutboundMessageEvent::class,
        cascade: ['persist'],
    )]
    #[ORM\OrderBy([
        'occurredAt' => 'ASC',
        'id' => 'ASC',
    ])]
    private Collection $events;

    public function __construct(string $idempotencyKey)
    {
        $length = strlen(
            $idempotencyKey,
        );

        if (
            $length === 0
            || $length > 255
            || trim($idempotencyKey) === ''
            || preg_match(
                '/[\x00-\x1F\x7F]/',
                $idempotencyKey,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Invalid outbound message idempotency key.',
            );
        }

        $this->idempotencyKeyHash = hash(
            'sha256',
            $idempotencyKey,
        );

        $this->status =
            OutboundMessageStatus::QUEUED;

        $this->createdAt =
            new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );

        $this->events =
            new ArrayCollection();

        $this->recordEvent(
            OutboundMessageEventType::QUEUED,
            $this->createdAt,
        );
    }

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getIdempotencyKeyHash(): string
    {
        return $this->idempotencyKeyHash;
    }

    public function getStatus(): OutboundMessageStatus
    {
        return $this->status;
    }

    public function getCreatedAt(): DateTimeImmutable
    {
        return $this->createdAt;
    }

    public function getReadyForSubmissionAt(): ?DateTimeImmutable
    {
        return $this->readyForSubmissionAt;
    }

    public function getSubmittingAt(): ?DateTimeImmutable
    {
        return $this->submittingAt;
    }

    public function getSubmissionUncertainAt(): ?DateTimeImmutable
    {
        return $this->submissionUncertainAt;
    }

    public function getSubmittedAt(): ?DateTimeImmutable
    {
        return $this->submittedAt;
    }

    /**
     * @return list<OutboundMessageEvent>
     */
    public function getEvents(): array
    {
        return array_values(
            $this->events->toArray(),
        );
    }

    public function markReadyForSubmission(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            !== OutboundMessageStatus::QUEUED
        ) {
            return;
        }

        $occurredAt = $at
            ?? self::now();

        $this->status =
            OutboundMessageStatus::READY_FOR_SUBMISSION;

        $this->readyForSubmissionAt =
            $occurredAt;

        $this->recordEvent(
            OutboundMessageEventType::READY_FOR_SUBMISSION,
            $occurredAt,
        );
    }

    /**
     * Marks the beginning of the irreversible SMTP boundary.
     *
     * This transition must be flushed before attempting SMTP.
     */
    public function markSubmitting(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            === OutboundMessageStatus::SUBMITTING
        ) {
            return;
        }

        if (
            $this->status
            !== OutboundMessageStatus::READY_FOR_SUBMISSION
        ) {
            throw new LogicException(
                'Outbound message must be ready before submission starts.',
            );
        }

        $occurredAt = $at
            ?? self::now();

        $this->status =
            OutboundMessageStatus::SUBMITTING;

        $this->submittingAt =
            $occurredAt;

        $this->recordEvent(
            OutboundMessageEventType::SUBMITTING,
            $occurredAt,
        );
    }

    /**
     * Marks an SMTP attempt whose definitive outcome is unknown.
     *
     * Automatic SMTP submission must never resume from this state.
     */
    public function markSubmissionUncertain(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            === OutboundMessageStatus::SUBMISSION_UNCERTAIN
        ) {
            return;
        }

        if (
            $this->status
            !== OutboundMessageStatus::SUBMITTING
        ) {
            throw new LogicException(
                'Only a submitting message can become submission uncertain.',
            );
        }

        $occurredAt = $at
            ?? self::now();

        $this->status =
            OutboundMessageStatus::SUBMISSION_UNCERTAIN;

        $this->submissionUncertainAt =
            $occurredAt;

        $this->recordEvent(
            OutboundMessageEventType::SUBMISSION_UNCERTAIN,
            $occurredAt,
        );
    }

    public function markSubmitted(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            === OutboundMessageStatus::SUBMITTED
        ) {
            return;
        }

        /*
         * READY_FOR_SUBMISSION remains accepted here for compatibility
         * with existing domain callers and tests. The production handler
         * always persists SUBMITTING before SMTP.
         */
        if (
            $this->status
            !== OutboundMessageStatus::SUBMITTING
            && $this->status
            !== OutboundMessageStatus::READY_FOR_SUBMISSION
        ) {
            throw new LogicException(
                'Outbound message must be ready or submitting before submission.',
            );
        }

        $occurredAt = $at
            ?? self::now();

        $this->status =
            OutboundMessageStatus::SUBMITTED;

        $this->submittedAt =
            $occurredAt;

        $this->recordEvent(
            OutboundMessageEventType::SUBMITTED,
            $occurredAt,
        );
    }

    public function recordDeliveryFeedback(
        OutboundMessageEventType $type,
        string $recipientHash,
        string $smtpStatus,
        string $detail,
        string $sourceEventId,
        ?DateTimeImmutable $at = null,
    ): void {
        if (!$type->isDelivery()) {
            throw new InvalidArgumentException(
                'Expected a delivery event type.',
            );
        }

        foreach ($this->events as $event) {
            if (
                $event->getSourceEventId()
                === $sourceEventId
            ) {
                return;
            }
        }

        $occurredAt = $at
            ?? self::now();

        /*
         * Postfix delivery evidence proves that the message crossed
         * the local submission boundary even if the worker crashed
         * before persisting SUBMITTED.
         */
        if (
            $this->status
            === OutboundMessageStatus::SUBMITTING
            || $this->status
            === OutboundMessageStatus::SUBMISSION_UNCERTAIN
        ) {
            $this->status =
                OutboundMessageStatus::SUBMITTED;

            $this->submittedAt ??=
                $occurredAt;

            $this->recordEvent(
                OutboundMessageEventType::SUBMITTED,
                $occurredAt,
            );
        }

        if (
            $this->status
            !== OutboundMessageStatus::SUBMITTED
        ) {
            throw new LogicException(
                'Delivery feedback requires a submitted outbound message.',
            );
        }

        $this->events->add(
            new OutboundMessageEvent(
                outboundMessage: $this,
                type: $type,
                occurredAt: $occurredAt,
                recipientHash: $recipientHash,
                smtpStatus: $smtpStatus,
                detail: $detail,
                sourceEventId: $sourceEventId,
            ),
        );
    }

    private function recordEvent(
        OutboundMessageEventType $type,
        DateTimeImmutable $occurredAt,
    ): void {
        $this->events->add(
            new OutboundMessageEvent(
                $this,
                $type,
                $occurredAt,
            ),
        );
    }

    private static function now(): DateTimeImmutable
    {
        return new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );
    }
}
