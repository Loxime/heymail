<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use DateTimeZone;
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
    private ?DateTimeImmutable $submittedAt = null;

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

    public function getSubmittedAt(): ?DateTimeImmutable
    {
        return $this->submittedAt;
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

        $this->status =
            OutboundMessageStatus::READY_FOR_SUBMISSION;

        $this->readyForSubmissionAt = $at
            ?? new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );
    }

    /**
     * Marks the beginning of the irreversible SMTP boundary.
     *
     * This transition must be flushed before attempting SMTP.
     */
    public function markSubmitting(): void
    {
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

        $this->status =
            OutboundMessageStatus::SUBMITTING;
    }

    /**
     * Marks an SMTP attempt whose definitive outcome is unknown.
     *
     * Automatic SMTP submission must never resume from this state.
     */
    public function markSubmissionUncertain(): void
    {
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

        $this->status =
            OutboundMessageStatus::SUBMISSION_UNCERTAIN;
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

        $this->status =
            OutboundMessageStatus::SUBMITTED;

        $this->submittedAt = $at
            ?? new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );
    }
}
