<?php

declare(strict_types=1);

namespace App\Automation;

use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;

final readonly class AutomationQuotaLimiter
{
    public function __construct(
        private Connection $connection,
        private int $limitPerHour,
    ) {
        if ($this->limitPerHour < 1) {
            throw new InvalidArgumentException(
                'Automation quota must be at least 1.',
            );
        }
    }

    /**
     * Returns null when the job is reserved.
     *
     * Returns Retry-After seconds when the current
     * workspace window has no remaining capacity.
     */
    public function reserve(
        int $workspaceId,
        int $jobId,
    ): ?int {
        if (
            $workspaceId < 1
            || $jobId < 1
        ) {
            throw new InvalidArgumentException(
                'Invalid automation quota scope.',
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

        $this->connection->beginTransaction();

        try {
            $this->connection->executeQuery(
                <<<'SQL'
SELECT pg_advisory_xact_lock(
    hashtextextended(:lock_key, 0)
)
SQL,
                [
                    'lock_key'
                        => sprintf(
                            'automation-quota:%d:%s',
                            $workspaceId,
                            $window->format(
                                'Y-m-d H:00:00',
                            ),
                        ),
                ],
            );

            $existing =
                (int) $this
                    ->connection
                    ->fetchOne(
                        <<<'SQL'
SELECT COUNT(*)
FROM automation_quota_reservation
WHERE workspace_id = :workspace_id
  AND window_started_at = :window_started_at
  AND automation_job_id = :job_id
SQL,
                        [
                            'workspace_id'
                                => $workspaceId,
                            'window_started_at'
                                => $window->format(
                                    'Y-m-d H:i:s',
                                ),
                            'job_id'
                                => $jobId,
                        ],
                    );

            if ($existing === 1) {
                $this->connection->commit();

                return null;
            }

            $used =
                (int) $this
                    ->connection
                    ->fetchOne(
                        <<<'SQL'
SELECT COUNT(*)
FROM automation_quota_reservation
WHERE workspace_id = :workspace_id
  AND window_started_at = :window_started_at
SQL,
                        [
                            'workspace_id'
                                => $workspaceId,
                            'window_started_at'
                                => $window->format(
                                    'Y-m-d H:i:s',
                                ),
                        ],
                    );

            if (
                $used
                >= $this->limitPerHour
            ) {
                $this->connection->commit();

                return max(
                    1,
                    $window
                        ->modify('+1 hour')
                        ->getTimestamp()
                    - $now->getTimestamp(),
                );
            }

            $this->connection->insert(
                'automation_quota_reservation',
                [
                    'workspace_id'
                        => $workspaceId,
                    'window_started_at'
                        => $window->format(
                            'Y-m-d H:i:s',
                        ),
                    'automation_job_id'
                        => $jobId,
                    'created_at'
                        => $now->format(
                            'Y-m-d H:i:s',
                        ),
                ],
            );

            $this->connection->commit();
        } catch (\Throwable $exception) {
            if (
                $this->connection
                    ->isTransactionActive()
            ) {
                $this->connection->rollBack();
            }

            throw $exception;
        }

        return null;
    }
}
