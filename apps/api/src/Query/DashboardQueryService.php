<?php

declare(strict_types=1);

namespace App\Query;

use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;

final readonly class DashboardQueryService
{
    public function __construct(
        private Connection $connection,
    ) {
    }

    /**
     * @return array<string, mixed>
     */
    public function query(
        DashboardPeriod $period,
    ): array {
        $parameters = [
            'from'
                => self::databaseTimestamp(
                    $period->from,
                ),
            'to'
                => self::databaseTimestamp(
                    $period->to,
                ),
        ];

        $messages =
            $this->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (
        WHERE status = 'queued'
    ) AS queued,
    COUNT(*) FILTER (
        WHERE status = 'ready_for_submission'
    ) AS ready_for_submission,
    COUNT(*) FILTER (
        WHERE status = 'submitting'
    ) AS submitting,
    COUNT(*) FILTER (
        WHERE status = 'submission_uncertain'
    ) AS submission_uncertain,
    COUNT(*) FILTER (
        WHERE status = 'submitted'
    ) AS submitted
FROM outbound_message
WHERE created_at >= :from
  AND created_at < :to
SQL,
                    $parameters,
                );

        if ($messages === false) {
            $messages = [];
        }

        $delivery =
            $this->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT
    COUNT(*) FILTER (
        WHERE event_type = 'delivered'
    ) AS delivered,
    COUNT(*) FILTER (
        WHERE event_type = 'tempfail'
    ) AS tempfail,
    COUNT(*) FILTER (
        WHERE event_type = 'bounced'
    ) AS bounced
FROM outbound_message_event
WHERE occurred_at >= :from
  AND occurred_at < :to
  AND event_type IN (
      'delivered',
      'tempfail',
      'bounced'
  )
SQL,
                    $parameters,
                );

        if ($delivery === false) {
            $delivery = [];
        }

        $delivered =
            (int) (
                $delivery['delivered']
                ?? 0
            );

        $tempfail =
            (int) (
                $delivery['tempfail']
                ?? 0
            );

        $bounced =
            (int) (
                $delivery['bounced']
                ?? 0
            );

        /*
         * TEMPFAIL is an attempt, not a terminal recipient outcome.
         */
        $terminal =
            $delivered
            + $bounced;

        $activity =
            $this->connection
                ->fetchAllAssociative(
                    <<<'SQL'
WITH days AS (
    SELECT generate_series(
        date_trunc(
            'day',
            CAST(:from AS timestamp)
        ),
        date_trunc(
            'day',
            CAST(:to AS timestamp)
            - INTERVAL '1 microsecond'
        ),
        INTERVAL '1 day'
    ) AS day
),
event_counts AS (
    SELECT
        date_trunc(
            'day',
            occurred_at
        ) AS day,
        COUNT(*) FILTER (
            WHERE event_type = 'submitted'
        ) AS submitted,
        COUNT(*) FILTER (
            WHERE event_type = 'tempfail'
        ) AS tempfail,
        COUNT(*) FILTER (
            WHERE event_type = 'delivered'
        ) AS delivered,
        COUNT(*) FILTER (
            WHERE event_type = 'bounced'
        ) AS bounced
    FROM outbound_message_event
    WHERE occurred_at >= :from
      AND occurred_at < :to
      AND event_type IN (
          'submitted',
          'tempfail',
          'delivered',
          'bounced'
      )
    GROUP BY
        date_trunc(
            'day',
            occurred_at
        )
)
SELECT
    to_char(
        days.day,
        'YYYY-MM-DD'
    ) AS date,
    COALESCE(
        event_counts.submitted,
        0
    ) AS submitted,
    COALESCE(
        event_counts.tempfail,
        0
    ) AS tempfail,
    COALESCE(
        event_counts.delivered,
        0
    ) AS delivered,
    COALESCE(
        event_counts.bounced,
        0
    ) AS bounced
FROM days
LEFT JOIN event_counts
    ON event_counts.day = days.day
ORDER BY days.day ASC
SQL,
                    $parameters,
                );

        return [
            'period' => [
                'from'
                    => $period
                        ->from
                        ->format(
                            DATE_ATOM,
                        ),
                'to'
                    => $period
                        ->to
                        ->format(
                            DATE_ATOM,
                        ),
            ],
            'messages' => [
                'total'
                    => (int) (
                        $messages['total']
                        ?? 0
                    ),
                'queued'
                    => (int) (
                        $messages['queued']
                        ?? 0
                    ),
                'readyForSubmission'
                    => (int) (
                        $messages[
                            'ready_for_submission'
                        ]
                        ?? 0
                    ),
                'submitting'
                    => (int) (
                        $messages['submitting']
                        ?? 0
                    ),
                'submissionUncertain'
                    => (int) (
                        $messages[
                            'submission_uncertain'
                        ]
                        ?? 0
                    ),
                'submitted'
                    => (int) (
                        $messages['submitted']
                        ?? 0
                    ),
            ],
            'delivery' => [
                'delivered'
                    => $delivered,
                'tempfail'
                    => $tempfail,
                'bounced'
                    => $bounced,
                'terminalOutcomes'
                    => $terminal,
                'deliveryRate'
                    => self::rate(
                        $delivered,
                        $terminal,
                    ),
                'bounceRate'
                    => self::rate(
                        $bounced,
                        $terminal,
                    ),
            ],
            'activity'
                => array_map(
                    static fn (
                        array $row,
                    ): array => [
                        'date'
                            => (string) $row[
                                'date'
                            ],
                        'submitted'
                            => (int) $row[
                                'submitted'
                            ],
                        'tempfail'
                            => (int) $row[
                                'tempfail'
                            ],
                        'delivered'
                            => (int) $row[
                                'delivered'
                            ],
                        'bounced'
                            => (int) $row[
                                'bounced'
                            ],
                    ],
                    $activity,
                ),
        ];
    }

    private static function rate(
        int $value,
        int $total,
    ): float {
        if ($total === 0) {
            return 0.0;
        }

        return round(
            $value / $total,
            4,
        );
    }

    private static function databaseTimestamp(
        DateTimeImmutable $value,
    ): string {
        return $value
            ->setTimezone(
                new DateTimeZone(
                    'UTC',
                ),
            )
            ->format(
                'Y-m-d H:i:s.u',
            );
    }
}
