<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\WebhookDelivery;
use App\Enum\WebhookDeliveryStatus;
use DateTimeImmutable;
use PHPUnit\Framework\TestCase;
use ReflectionClass;

final class WebhookDeliveryTest extends TestCase
{
    public function testRetryScheduleEndsDead(): void
    {
        $reflection =
            new ReflectionClass(
                WebhookDelivery::class,
            );

        $delivery =
            $reflection
                ->newInstanceWithoutConstructor();

        $set = static function (
            string $property,
            mixed $value,
        ) use (
            $reflection,
            $delivery,
        ): void {
            $reflection
                ->getProperty(
                    $property,
                )
                ->setValue(
                    $delivery,
                    $value,
                );
        };

        $set(
            'status',
            WebhookDeliveryStatus::PENDING,
        );

        $set(
            'attemptCount',
            0,
        );

        $set(
            'queuedAt',
            new DateTimeImmutable(
                '2042-01-01T00:00:00+00:00',
            ),
        );

        $set(
            'nextAttemptAt',
            null,
        );

        $set(
            'succeededAt',
            null,
        );

        $set(
            'lastError',
            null,
        );

        $at =
            new DateTimeImmutable(
                '2042-01-01T00:00:00+00:00',
            );

        $expected = [
            5,
            30,
            120,
            600,
        ];

        foreach ($expected as $offset) {
            $delivery->markFailedAttempt(
                'temporary',
                $at,
            );

            self::assertSame(
                WebhookDeliveryStatus::PENDING,
                $delivery->getStatus(),
            );

            self::assertEquals(
                $at->modify(
                    sprintf(
                        '+%d seconds',
                        $offset,
                    ),
                ),
                $delivery
                    ->getNextAttemptAt(),
            );
        }

        $delivery->markFailedAttempt(
            'permanent',
            $at,
        );

        self::assertSame(
            WebhookDeliveryStatus::DEAD,
            $delivery->getStatus(),
        );

        self::assertSame(
            5,
            $delivery->getAttemptCount(),
        );

        self::assertNull(
            $delivery->getNextAttemptAt(),
        );
    }
}
