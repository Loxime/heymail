<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use InvalidArgumentException;

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
    // Doctrine assigns the generated identifier after persistence.
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

    public function __construct(string $idempotencyKey)
    {
        $length = strlen($idempotencyKey);

        if (
            $length === 0
            || $length > 255
            || trim($idempotencyKey) === ''
            || preg_match('/[\x00-\x1F\x7F]/', $idempotencyKey) === 1
        ) {
            throw new InvalidArgumentException(
                'Invalid outbound message idempotency key.',
            );
        }

        $this->idempotencyKeyHash = hash(
            'sha256',
            $idempotencyKey,
        );

        $this->status = OutboundMessageStatus::QUEUED;

        $this->createdAt = new DateTimeImmutable(
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

    public function markReadyForSubmission(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            === OutboundMessageStatus::READY_FOR_SUBMISSION
        ) {
            return;
        }

        $this->status = OutboundMessageStatus::READY_FOR_SUBMISSION;

        $this->readyForSubmissionAt = $at
            ?? new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );
    }
}
