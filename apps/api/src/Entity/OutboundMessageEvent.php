<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\OutboundMessageEventType;
use DateTimeImmutable;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use InvalidArgumentException;

#[ORM\Entity]
#[ORM\Table(name: 'outbound_message_event')]
#[ORM\UniqueConstraint(
    name: 'uniq_outbound_message_event_source',
    columns: ['source_event_id'],
)]
#[ORM\Index(
    name: 'idx_outbound_message_event_timeline',
    columns: [
        'outbound_message_id',
        'occurred_at',
        'id',
    ],
)]
#[ORM\Index(
    name: 'idx_outbound_message_event_recipient',
    columns: [
        'outbound_message_id',
        'recipient_hash',
        'occurred_at',
        'id',
    ],
)]
#[ORM\Index(
    name: 'idx_outbound_message_event_type_message',
    columns: [
        'event_type',
        'outbound_message_id',
    ],
)]
#[ORM\Index(
    name: 'idx_outbound_message_event_occurred_type',
    columns: [
        'occurred_at',
        'event_type',
    ],
)]
final class OutboundMessageEvent
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    // @phpstan-ignore property.unusedType
    private ?int $id = null;

    #[ORM\ManyToOne(
        targetEntity: OutboundMessage::class,
        inversedBy: 'events',
    )]
    #[ORM\JoinColumn(
        name: 'outbound_message_id',
        referencedColumnName: 'id',
        nullable: false,
        onDelete: 'CASCADE',
    )]
    private OutboundMessage $outboundMessage;

    #[ORM\Column(
        name: 'event_type',
        type: Types::STRING,
        length: 32,
        enumType: OutboundMessageEventType::class,
    )]
    private OutboundMessageEventType $type;

    #[ORM\Column(
        name: 'occurred_at',
        type: Types::DATETIME_IMMUTABLE,
    )]
    private DateTimeImmutable $occurredAt;

    #[ORM\Column(
        name: 'recipient_hash',
        type: Types::STRING,
        length: 64,
        nullable: true,
    )]
    private ?string $recipientHash;

    #[ORM\Column(
        name: 'smtp_status',
        type: Types::STRING,
        length: 16,
        nullable: true,
    )]
    private ?string $smtpStatus;

    #[ORM\Column(
        type: Types::STRING,
        length: 1024,
        nullable: true,
    )]
    private ?string $detail;

    #[ORM\Column(
        name: 'source_event_id',
        type: Types::STRING,
        length: 64,
        nullable: true,
    )]
    private ?string $sourceEventId;

    public function __construct(
        OutboundMessage $outboundMessage,
        OutboundMessageEventType $type,
        DateTimeImmutable $occurredAt,
        ?string $recipientHash = null,
        ?string $smtpStatus = null,
        ?string $detail = null,
        ?string $sourceEventId = null,
    ) {
        if ($type->isDelivery()) {
            if (
                $recipientHash === null
                || preg_match(
                    '/^[a-f0-9]{64}$/D',
                    $recipientHash,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'Delivery event requires a valid recipient hash.',
                );
            }

            if (
                $smtpStatus === null
                || preg_match(
                    '/^[245]\.[0-9]{1,3}\.[0-9]{1,3}$/D',
                    $smtpStatus,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'Delivery event requires a valid SMTP status.',
                );
            }

            if (
                $sourceEventId === null
                || preg_match(
                    '/^[a-f0-9]{64}$/D',
                    $sourceEventId,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'Delivery event requires a valid source identifier.',
                );
            }

            if (
                $detail === null
                || $detail === ''
                || strlen($detail) > 1024
            ) {
                throw new InvalidArgumentException(
                    'Delivery event requires a bounded diagnostic.',
                );
            }
        } elseif (
            $recipientHash !== null
            || $smtpStatus !== null
            || $detail !== null
            || $sourceEventId !== null
        ) {
            throw new InvalidArgumentException(
                'Lifecycle events cannot contain delivery metadata.',
            );
        }

        $this->outboundMessage = $outboundMessage;
        $this->type = $type;
        $this->occurredAt = $occurredAt;
        $this->recipientHash = $recipientHash;
        $this->smtpStatus = $smtpStatus;
        $this->detail = $detail;
        $this->sourceEventId = $sourceEventId;
    }

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getOutboundMessage(): OutboundMessage
    {
        return $this->outboundMessage;
    }

    public function getType(): OutboundMessageEventType
    {
        return $this->type;
    }

    public function getOccurredAt(): DateTimeImmutable
    {
        return $this->occurredAt;
    }

    public function getRecipientHash(): ?string
    {
        return $this->recipientHash;
    }

    public function getSmtpStatus(): ?string
    {
        return $this->smtpStatus;
    }

    public function getDetail(): ?string
    {
        return $this->detail;
    }

    public function getSourceEventId(): ?string
    {
        return $this->sourceEventId;
    }
}
