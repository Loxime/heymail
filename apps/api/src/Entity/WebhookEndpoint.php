<?php

declare(strict_types=1);

namespace App\Entity;

use App\Enum\OutboundMessageEventType;
use App\Webhook\EncryptedWebhookSecret;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\Common\Collections\ArrayCollection;
use Doctrine\Common\Collections\Collection;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;
use InvalidArgumentException;

#[ORM\Entity]
#[ORM\Table(name: 'webhook_endpoint')]
#[ORM\UniqueConstraint(
    name: 'uniq_webhook_endpoint_public_id',
    columns: ['public_id'],
)]
#[ORM\Index(
    name: 'idx_webhook_endpoint_workspace',
    columns: [
        'workspace_id',
        'id',
    ],
)]
final class WebhookEndpoint
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: Types::BIGINT)]
    private ?int $id = null;

    #[ORM\Column(
        name: 'workspace_id',
        type: Types::BIGINT,
        nullable: true,
    )]
    private ?int $workspaceId = null;

    #[ORM\Column(
        name: 'public_id',
        type: Types::STRING,
        length: 35,
    )]
    private string $publicId;

    #[ORM\Column(
        type: Types::STRING,
        length: 2048,
    )]
    private string $url;

    #[ORM\Column(
        type: Types::BOOLEAN,
    )]
    private bool $enabled = true;

    #[ORM\Column(
        name: 'starts_after_event_id',
        type: Types::BIGINT,
    )]
    private int $startsAfterEventId;

    #[ORM\Column(
        name: 'secret_ciphertext',
        type: Types::TEXT,
    )]
    private string $secretCiphertext;

    #[ORM\Column(
        name: 'secret_nonce',
        type: Types::STRING,
        length: 64,
    )]
    private string $secretNonce;

    #[ORM\Column(
        name: 'secret_algorithm',
        type: Types::STRING,
        length: 64,
    )]
    private string $secretAlgorithm;

    #[ORM\Column(
        name: 'secret_key_version',
        type: Types::SMALLINT,
    )]
    private int $secretKeyVersion;

    #[ORM\Column(
        name: 'created_at',
        type: Types::DATETIME_IMMUTABLE,
    )]
    private DateTimeImmutable $createdAt;

    /**
     * @var Collection<int, WebhookEndpointSubscription>
     */
    #[ORM\OneToMany(
        mappedBy: 'endpoint',
        targetEntity: WebhookEndpointSubscription::class,
        cascade: ['persist'],
        orphanRemoval: true,
    )]
    private Collection $subscriptions;

    /**
     * @param list<OutboundMessageEventType> $eventTypes
     */
    public function __construct(
        string $publicId,
        string $url,
        int $startsAfterEventId,
        EncryptedWebhookSecret $secret,
        array $eventTypes,
        ?int $workspaceId = null,
    ) {
        if (
            $workspaceId !== null
            && $workspaceId < 1
        ) {
            throw new InvalidArgumentException(
                'Invalid webhook workspace.',
            );
        }

        $this->workspaceId = $workspaceId;

        if (
            preg_match(
                '/^wh_[a-f0-9]{32}$/D',
                $publicId,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid webhook public identifier.',
            );
        }

        self::assertUrl(
            $url,
        );

        if ($startsAfterEventId < 0) {
            throw new InvalidArgumentException(
                'Invalid webhook event watermark.',
            );
        }

        if ($eventTypes === []) {
            throw new InvalidArgumentException(
                'Webhook must subscribe to at least one event.',
            );
        }

        $seen = [];

        foreach ($eventTypes as $eventType) {
            if (!$eventType->isDelivery()) {
                throw new InvalidArgumentException(
                    'Webhook subscriptions currently support delivery events only.',
                );
            }

            if (isset($seen[$eventType->value])) {
                throw new InvalidArgumentException(
                    'Duplicate webhook event subscription.',
                );
            }

            $seen[$eventType->value] = true;
        }

        $this->publicId = $publicId;
        $this->url = $url;
        $this->startsAfterEventId =
            $startsAfterEventId;

        $this->secretCiphertext =
            $secret->ciphertext;

        $this->secretNonce =
            $secret->nonce;

        $this->secretAlgorithm =
            $secret->algorithm;

        $this->secretKeyVersion =
            $secret->keyVersion;

        $this->createdAt =
            new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );

        $this->subscriptions =
            new ArrayCollection();

        foreach ($eventTypes as $eventType) {
            $this->subscriptions->add(
                new WebhookEndpointSubscription(
                    $this,
                    $eventType,
                ),
            );
        }
    }

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getWorkspaceId(): ?int
    {
        return $this->workspaceId;
    }

    public function getPublicId(): string
    {
        return $this->publicId;
    }

    public function getUrl(): string
    {
        return $this->url;
    }

    public function isEnabled(): bool
    {
        return $this->enabled;
    }

    public function getStartsAfterEventId(): int
    {
        return $this->startsAfterEventId;
    }

    public function getCreatedAt(): DateTimeImmutable
    {
        return $this->createdAt;
    }

    /**
     * @return list<OutboundMessageEventType>
     */
    public function getEventTypes(): array
    {
        return array_values(
            array_map(
                static fn (
                    WebhookEndpointSubscription $subscription,
                ): OutboundMessageEventType
                    => $subscription
                        ->getEventType(),
                $this->subscriptions->toArray(),
            ),
        );
    }

    public function encryptedSecret(): EncryptedWebhookSecret
    {
        return new EncryptedWebhookSecret(
            ciphertext:
                $this->secretCiphertext,
            nonce:
                $this->secretNonce,
            algorithm:
                $this->secretAlgorithm,
            keyVersion:
                $this->secretKeyVersion,
        );
    }

    private static function assertUrl(
        string $url,
    ): void {
        if (
            $url === ''
            || strlen($url) > 2048
            || filter_var(
                $url,
                FILTER_VALIDATE_URL,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Invalid webhook URL.',
            );
        }

        $parts = parse_url(
            $url,
        );

        if (
            !is_array($parts)
            || strtolower(
                (string) (
                    $parts['scheme']
                    ?? ''
                ),
            ) !== 'https'
            || !isset($parts['host'])
            || $parts['host'] === ''
            || isset($parts['user'])
            || isset($parts['pass'])
            || isset($parts['fragment'])
        ) {
            throw new InvalidArgumentException(
                'Webhook URL must be HTTPS without credentials or fragment.',
            );
        }
    }
}
