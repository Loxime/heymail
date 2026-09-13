<?php

declare(strict_types=1);

namespace App\Api;

use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use RuntimeException;

final readonly class ApiSendQuotaLimiter
{
    public function __construct(
        private Connection $connection,
        private int $limitPerHour,
    ) {
        if ($this->limitPerHour < 1) {
            throw new InvalidArgumentException(
                'API send quota must be at least 1.',
            );
        }
    }

    /**
     * Returns null when the request is allowed.
     *
     * Returns the Retry-After value in seconds when
     * the hourly quota has been exceeded.
     */
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

        $windowStartedAt = $now->setTime(
            (int) $now->format('H'),
            0,
            0,
        );

        $count = $this->connection->fetchOne(
            <<<'SQL'
INSERT INTO api_send_quota_hour (
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
DO UPDATE
SET request_count =
    api_send_quota_hour.request_count + 1
RETURNING request_count
SQL,
            [
                'api_key_fingerprint'
                    => $apiKeyFingerprint,
                'window_started_at'
                    => $windowStartedAt->format(
                        'Y-m-d H:i:s',
                    ),
            ],
        );

        if (
            !is_int($count)
            && !is_string($count)
        ) {
            throw new RuntimeException(
                'Unable to update API send quota.',
            );
        }

        if ((int) $count <= $this->limitPerHour) {
            return null;
        }

        $nextWindow =
            $windowStartedAt->modify(
                '+1 hour',
            );

        return max(
            1,
            $nextWindow->getTimestamp()
            - $now->getTimestamp(),
        );
    }
}
