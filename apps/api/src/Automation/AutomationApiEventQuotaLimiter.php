<?php

declare(strict_types=1);

namespace App\Automation;

use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use RuntimeException;

final readonly class AutomationApiEventQuotaLimiter
{
    public function __construct(
        private Connection $connection,
        private int $limitPerHour,
    ) {
        if ($this->limitPerHour < 1) {
            throw new InvalidArgumentException(
                'Automation API-event quota must be at least 1.',
            );
        }
    }

    public function consume(
        string $apiKeyFingerprint,
    ): ?int {
        if (
            preg_match(
                '/^[a-f0-9]{64}$/D',
                $apiKeyFingerprint,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid API key fingerprint.',
            );
        }

        $now = new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );

        $window =
            $now->setTime(
                (int) $now->format('H'),
                0,
                0,
            );

        $count =
            $this
                ->connection
                ->fetchOne(
                    <<<'SQL'
INSERT INTO automation_api_event_quota_hour (
    api_key_fingerprint,
    window_started_at,
    request_count
)
VALUES (
    :api_key_fingerprint,
    :window_started_at,
    1
)
ON CONFLICT (
    api_key_fingerprint,
    window_started_at
)
DO UPDATE SET
    request_count =
        automation_api_event_quota_hour.request_count + 1
RETURNING request_count
SQL,
                    [
                        'api_key_fingerprint'
                            => $apiKeyFingerprint,
                        'window_started_at'
                            => $window->format(
                                'Y-m-d H:i:s',
                            ),
                    ],
                );

        if (
            !is_int($count)
            && !is_string($count)
        ) {
            throw new RuntimeException(
                'Unable to update automation API-event quota.',
            );
        }

        if ((int) $count <= $this->limitPerHour) {
            return null;
        }

        return max(
            1,
            $window
                ->modify('+1 hour')
                ->getTimestamp()
            - $now->getTimestamp(),
        );
    }
}
