<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\OutboundMessageStatus;
use DateTimeImmutable;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity]
#[ORM\Table(name: 'outbound_message_event')]
#[ORM\Index(
    name: 'idx_outbound_message_event_timeline',
    columns: [
        'outbound_message_id',
        'occurred_at',
        'id',
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
        enumType: OutboundMessageStatus::class,
    )]
    private OutboundMessageStatus $type;

    #[ORM\Column(
        name: 'occurred_at',
        type: Types::DATETIME_IMMUTABLE,
    )]
    private DateTimeImmutable $occurredAt;

    public function __construct(
        OutboundMessage $outboundMessage,
        OutboundMessageStatus $type,
        DateTimeImmutable $occurredAt,
    ) {
        $this->outboundMessage = $outboundMessage;
        $this->type = $type;
        $this->occurredAt = $occurredAt;
    }

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getOutboundMessage(): OutboundMessage
    {
        return $this->outboundMessage;
    }

    public function getType(): OutboundMessageStatus
    {
        return $this->type;
    }

    public function getOccurredAt(): DateTimeImmutable
    {
        return $this->occurredAt;
    }
}
