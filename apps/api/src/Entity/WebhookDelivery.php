<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\WebhookDeliveryStatus;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use InvalidArgumentException;
use LogicException;

#[ORM\Entity]
#[ORM\Table(name: 'webhook_delivery')]
#[ORM\UniqueConstraint(
    name: 'uniq_webhook_delivery_public_id',
    columns: ['public_id'],
)]
#[ORM\UniqueConstraint(
    name: 'uniq_webhook_delivery_event_endpoint',
    columns: [
        'webhook_endpoint_id',
        'outbound_message_event_id',
    ],
)]
#[ORM\Index(
    name: 'idx_webhook_delivery_pending',
    columns: [
        'status',
        'next_attempt_at',
        'queued_at',
        'id',
    ],
)]
final class WebhookDelivery
{
    public const int MAX_ATTEMPTS = 5;

    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    private ?int $id = null;

    #[ORM\Column(
        name: 'public_id',
        type: Types::STRING,
        length: 36,
    )]
    private string $publicId;

    #[ORM\ManyToOne(
        targetEntity: WebhookEndpoint::class,
    )]
    #[ORM\JoinColumn(
        name: 'webhook_endpoint_id',
        referencedColumnName: 'id',
        nullable: false,
        onDelete: 'RESTRICT',
    )]
    private WebhookEndpoint $endpoint;

    #[ORM\ManyToOne(
        targetEntity: OutboundMessageEvent::class,
    )]
    #[ORM\JoinColumn(
        name: 'outbound_message_event_id',
        referencedColumnName: 'id',
        nullable: false,
        onDelete: 'CASCADE',
    )]
    private OutboundMessageEvent $event;

    #[ORM\Column(
        type: Types::STRING,
        length: 32,
        enumType: WebhookDeliveryStatus::class,
    )]
    private WebhookDeliveryStatus $status;

    #[ORM\Column(
        name: 'attempt_count',
        type: Types::SMALLINT,
    )]
    private int $attemptCount;

    #[ORM\Column(
        name: 'queued_at',
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $queuedAt;

    #[ORM\Column(
        name: 'next_attempt_at',
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $nextAttemptAt;

    #[ORM\Column(
        name: 'succeeded_at',
        type: Types::DATETIME_IMMUTABLE,
        nullable: true,
    )]
    private ?DateTimeImmutable $succeededAt;

    #[ORM\Column(
        name: 'last_error',
        type: Types::STRING,
        length: 512,
        nullable: true,
    )]
    private ?string $lastError;

    #[ORM\Column(
        name: 'created_at',
        type: Types::DATETIME_IMMUTABLE,
    )]
    private DateTimeImmutable $createdAt;

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getPublicId(): string
    {
        return $this->publicId;
    }

    public function getEndpoint(): WebhookEndpoint
    {
        return $this->endpoint;
    }

    public function getEvent(): OutboundMessageEvent
    {
        return $this->event;
    }

    public function getStatus(): WebhookDeliveryStatus
    {
        return $this->status;
    }

    public function getAttemptCount(): int
    {
        return $this->attemptCount;
    }

    public function getNextAttemptAt(): ?DateTimeImmutable
    {
        return $this->nextAttemptAt;
    }

    public function getLastError(): ?string
    {
        return $this->lastError;
    }

    public function markSucceeded(
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            === WebhookDeliveryStatus::SUCCEEDED
        ) {
            return;
        }

        if (
            $this->status
            !== WebhookDeliveryStatus::PENDING
        ) {
            throw new LogicException(
                'Only pending webhook delivery can succeed.',
            );
        }

        $this->attemptCount++;

        $this->status =
            WebhookDeliveryStatus::SUCCEEDED;

        $this->queuedAt = null;
        $this->nextAttemptAt = null;
        $this->lastError = null;

        $this->succeededAt =
            $at
            ?? self::now();
    }

    public function markFailedAttempt(
        string $error,
        ?DateTimeImmutable $at = null,
    ): void {
        if (
            $this->status
            !== WebhookDeliveryStatus::PENDING
        ) {
            return;
        }

        $error =
            trim(
                preg_replace(
                    '/[\x00-\x1F\x7F]+/',
                    ' ',
                    $error,
                )
                ?? '',
            );

        if ($error === '') {
            $error =
                'Webhook delivery failed.';
        }

        if (strlen($error) > 512) {
            $error =
                substr(
                    $error,
                    0,
                    512,
                );
        }

        $this->attemptCount++;
        $this->queuedAt = null;
        $this->lastError = $error;

        $occurredAt =
            $at
            ?? self::now();

        if (
            $this->attemptCount
            >= self::MAX_ATTEMPTS
        ) {
            $this->status =
                WebhookDeliveryStatus::DEAD;

            $this->nextAttemptAt = null;

            return;
        }

        $delaySeconds = match (
            $this->attemptCount
        ) {
            1 => 5,
            2 => 30,
            3 => 120,
            4 => 600,

            default => throw new InvalidArgumentException(
                'Invalid webhook retry attempt.',
            ),
        };

        $this->nextAttemptAt =
            $occurredAt->modify(
                sprintf(
                    '+%d seconds',
                    $delaySeconds,
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
