<?php

declare(strict_types=1);

namespace App\Webhook;

use App\Entity\WebhookEndpoint;
use App\Enum\OutboundMessageEventType;
use Doctrine\ORM\EntityManagerInterface;

final readonly class WebhookRegistrationService
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private WebhookSecretCipher $secretCipher,
    ) {
    }

    /**
     * @param list<OutboundMessageEventType> $eventTypes
     */
    public function create(
        string $url,
        array $eventTypes,
    ): WebhookRegistration {
        $connection =
            $this->entityManager
                ->getConnection();

        $watermark =
            (int) $connection
                ->fetchOne(
                    <<<'SQL'
SELECT COALESCE(MAX(id), 0)
FROM outbound_message_event
SQL
                );

        $publicId =
            'wh_'
            . bin2hex(
                random_bytes(16),
            );

        $secret =
            'whsec_'
            . self::base64Url(
                random_bytes(32),
            );

        $encrypted =
            $this
                ->secretCipher
                ->encrypt(
                    $publicId,
                    $secret,
                );

        $endpoint =
            new WebhookEndpoint(
                publicId: $publicId,
                url: $url,
                startsAfterEventId: $watermark,
                secret: $encrypted,
                eventTypes: $eventTypes,
            );

        $this->entityManager->persist(
            $endpoint,
        );

        $this->entityManager->flush();

        return new WebhookRegistration(
            endpoint: $endpoint,
            secret: $secret,
        );
    }

    /**
     * @return list<WebhookEndpoint>
     */
    public function all(): array
    {
        return $this
            ->entityManager
            ->getRepository(
                WebhookEndpoint::class,
            )
            ->findBy(
                [],
                [
                    'id' => 'DESC',
                ],
            );
    }

    private static function base64Url(
        string $value,
    ): string {
        return rtrim(
            strtr(
                base64_encode(
                    $value,
                ),
                '+/',
                '-_',
            ),
            '=',
        );
    }
}
