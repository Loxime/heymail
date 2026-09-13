<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\OutboundMessageEventType;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity]
#[ORM\Table(name: 'webhook_endpoint_subscription')]
#[ORM\UniqueConstraint(
    name: 'uniq_webhook_endpoint_subscription',
    columns: [
        'webhook_endpoint_id',
        'event_type',
    ],
)]
#[ORM\Index(
    name: 'idx_webhook_subscription_event',
    columns: [
        'event_type',
        'webhook_endpoint_id',
    ],
)]
final class WebhookEndpointSubscription
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    private ?int $id = null;

    #[ORM\ManyToOne(
        targetEntity: WebhookEndpoint::class,
        inversedBy: 'subscriptions',
    )]
    #[ORM\JoinColumn(
        name: 'webhook_endpoint_id',
        referencedColumnName: 'id',
        nullable: false,
        onDelete: 'CASCADE',
    )]
    private WebhookEndpoint $endpoint;

    #[ORM\Column(
        name: 'event_type',
        type: Types::STRING,
        length: 32,
        enumType: OutboundMessageEventType::class,
    )]
    private OutboundMessageEventType $eventType;

    public function __construct(
        WebhookEndpoint $endpoint,
        OutboundMessageEventType $eventType,
    ) {
        $this->endpoint = $endpoint;
        $this->eventType = $eventType;
    }

    public function getEventType(): OutboundMessageEventType
    {
        return $this->eventType;
    }
}
