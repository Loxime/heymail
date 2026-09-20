<?php

declare(strict_types=1);

namespace App\Campaign;

use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;

final readonly class CampaignQuotaLimiter
{
    public function __construct(
        private Connection $connection,
        private int $limitPerHour,
    ) {
        if ($this->limitPerHour < 1) {
            throw new InvalidArgumentException(
                'Campaign quota must be at least 1.',
            );
        }
    }

    /**
     * @param list<int> $recipientIndexes
     *
     * @return array{
     *     indexes:list<int>,
     *     retryAfter:int|null
     * }
     */
    public function reserve(
        int $workspaceId,
        int $campaignId,
        array $recipientIndexes,
    ): array {
        if ($workspaceId < 1 || $campaignId < 1) {
            throw new InvalidArgumentException(
                'Invalid campaign quota scope.',
            );
        }

        if ($recipientIndexes === []) {
            return [
                'indexes' => [],
                'retryAfter' => null,
            ];
        }

        foreach ($recipientIndexes as $index) {
            if (!is_int($index) || $index < 0) {
                throw new InvalidArgumentException(
                    'Invalid campaign recipient index.',
                );
            }
        }

        $now = new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );

        $window = $now->setTime(
            (int) $now->format('H'),
            0,
            0,
        );

        $this->connection->beginTransaction();

        try {
            $this->connection->executeQuery(
                <<<'SQL'
SELECT pg_advisory_xact_lock(
    hashtextextended(:lock_key, 0)
)
SQL,
                [
                    'lock_key' => sprintf(
                        'campaign-quota:%d:%s',
                        $workspaceId,
                        $window->format('Y-m-d H:00:00'),
                    ),
                ],
            );

            $used = (int) $this->connection->fetchOne(
                <<<'SQL'
SELECT COUNT(*)
FROM campaign_quota_reservation
WHERE workspace_id = :workspace_id
  AND window_started_at = :window_started_at
SQL,
                [
                    'workspace_id' => $workspaceId,
                    'window_started_at' => $window->format('Y-m-d H:i:s'),
                ],
            );

            $reserved = [];
            $remaining = max(
                0,
                $this->limitPerHour - $used,
            );

            foreach ($recipientIndexes as $index) {
                $exists = (int) $this->connection->fetchOne(
                    <<<'SQL'
SELECT COUNT(*)
FROM campaign_quota_reservation
WHERE workspace_id = :workspace_id
  AND window_started_at = :window_started_at
  AND campaign_id = :campaign_id
  AND recipient_index = :recipient_index
SQL,
                    [
                        'workspace_id' => $workspaceId,
                        'window_started_at' => $window->format('Y-m-d H:i:s'),
                        'campaign_id' => $campaignId,
                        'recipient_index' => $index,
                    ],
                );

                if ($exists === 1) {
                    $reserved[] = $index;
                    continue;
                }

                if ($remaining < 1) {
                    break;
                }

                $this->connection->insert(
                    'campaign_quota_reservation',
                    [
                        'workspace_id' => $workspaceId,
                        'window_started_at' => $window->format('Y-m-d H:i:s'),
                        'campaign_id' => $campaignId,
                        'recipient_index' => $index,
                        'created_at' => $now->format('Y-m-d H:i:s'),
                    ],
                );

                --$remaining;
                $reserved[] = $index;
            }

            $this->connection->commit();
        } catch (\Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }

        $retryAfter = count($reserved) === count($recipientIndexes)
            ? null
            : max(
                1,
                $window
                    ->modify('+1 hour')
                    ->getTimestamp()
                - $now->getTimestamp(),
            );

        return [
            'indexes' => $reserved,
            'retryAfter' => $retryAfter,
        ];
    }
}
