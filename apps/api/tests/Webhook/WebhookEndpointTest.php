<?php

declare(strict_types=1);

namespace App\Tests\Webhook;

use App\Entity\WebhookEndpoint;
use App\Enum\OutboundMessageEventType;
use App\Webhook\EncryptedWebhookSecret;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class WebhookEndpointTest extends TestCase
{
    public function testAcceptsDeliverySubscriptions(): void
    {
        $endpoint =
            new WebhookEndpoint(
                publicId:
                    'wh_'
                    . str_repeat(
                        'a',
                        32,
                    ),
                url:
                    'https://hooks.example.test/heymail',
                startsAfterEventId: 42,
                secret:
                    self::encryptedSecret(),
                eventTypes: [
                    OutboundMessageEventType::DELIVERED,
                    OutboundMessageEventType::BOUNCED,
                ],
            );

        self::assertSame(
            [
                OutboundMessageEventType::DELIVERED,
                OutboundMessageEventType::BOUNCED,
            ],
            $endpoint->getEventTypes(),
        );
    }

    public function testRejectsPlainHttp(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new WebhookEndpoint(
            publicId:
                'wh_'
                . str_repeat(
                    'a',
                    32,
                ),
            url:
                'http://hooks.example.test/heymail',
            startsAfterEventId: 0,
            secret:
                self::encryptedSecret(),
            eventTypes: [
                OutboundMessageEventType::DELIVERED,
            ],
        );
    }

    public function testRejectsLifecycleEvents(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new WebhookEndpoint(
            publicId:
                'wh_'
                . str_repeat(
                    'a',
                    32,
                ),
            url:
                'https://hooks.example.test/heymail',
            startsAfterEventId: 0,
            secret:
                self::encryptedSecret(),
            eventTypes: [
                OutboundMessageEventType::SUBMITTED,
            ],
        );
    }

    private static function encryptedSecret(): EncryptedWebhookSecret
    {
        return new EncryptedWebhookSecret(
            ciphertext: 'ciphertext',
            nonce: 'nonce',
            algorithm: 'test',
            keyVersion: 1,
        );
    }
}
