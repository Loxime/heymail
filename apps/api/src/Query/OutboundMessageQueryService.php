<?php

declare(strict_types=1);

namespace App\Query;

use App\Enum\OutboundMessageEventType;
use App\Enum\OutboundMessageStatus;
use App\Workspace\LegacyApiWorkspace;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\ParameterType;

final readonly class OutboundMessageQueryService
{
    public function __construct(
        private Connection $connection,
        private MessageCursorCodec $cursorCodec,
        private LegacyApiWorkspace $legacyApiWorkspace,
    ) {
    }

    /**
     * @return array{
     *     items: list<array{
     *         messageId: int,
     *         status: string,
     *         createdAt: string,
     *         readyForSubmissionAt: ?string,
     *         submittingAt: ?string,
     *         submissionUncertainAt: ?string,
     *         submittedAt: ?string,
     *         deliverySummary: array{
     *             delivered: int,
     *             tempfail: int,
     *             bounced: int
     *         }
     *     }>,
     *     nextCursor: ?string
     * }
     */
    public function list(
        int $workspaceId,
        int $limit,
        ?string $cursor,
        ?OutboundMessageStatus $status,
        ?OutboundMessageEventType $event,
        ?DateTimeImmutable $createdAfter,
        ?DateTimeImmutable $createdBefore,
    ): array {
        $where = [
            <<<'SQL'
(
    om.workspace_id = :workspace_id
    OR (
        om.workspace_id IS NULL
        AND :workspace_id = :legacy_workspace_id
    )
)
SQL,
        ];

        $parameters = [
            'workspace_id'
                => $workspaceId,
            'legacy_workspace_id'
                => $this
                    ->legacyApiWorkspace
                    ->id(),
        ];

        $types = [
            'workspace_id'
                => ParameterType::INTEGER,
            'legacy_workspace_id'
                => ParameterType::INTEGER,
        ];

        if ($cursor !== null) {
            $where[] =
                'om.id < :cursor_id';

            $parameters['cursor_id'] =
                $this
                    ->cursorCodec
                    ->decode(
                        $cursor,
                    );

            $types['cursor_id'] =
                ParameterType::INTEGER;
        }

        if ($status !== null) {
            $where[] =
                'om.status = :status';

            $parameters['status'] =
                $status->value;
        }

        if ($event !== null) {
            $where[] =
                <<<'SQL'
EXISTS (
    SELECT 1
    FROM outbound_message_event filter_event
    WHERE filter_event.outbound_message_id = om.id
      AND filter_event.event_type = :event_type
)
SQL;

            $parameters['event_type'] =
                $event->value;
        }

        if ($createdAfter !== null) {
            $where[] =
                'om.created_at >= :created_after';

            $parameters['created_after'] =
                self::databaseTimestamp(
                    $createdAfter,
                );
        }

        if ($createdBefore !== null) {
            $where[] =
                'om.created_at < :created_before';

            $parameters['created_before'] =
                self::databaseTimestamp(
                    $createdBefore,
                );
        }

        $sql =
            <<<'SQL'
SELECT
    om.id,
    om.status,
    om.created_at,
    om.ready_for_submission_at,
    om.submitting_at,
    om.submission_uncertain_at,
    om.submitted_at,
    COUNT(ome.id) FILTER (
        WHERE ome.event_type = 'delivered'
    ) AS delivered_count,
    COUNT(ome.id) FILTER (
        WHERE ome.event_type = 'tempfail'
    ) AS tempfail_count,
    COUNT(ome.id) FILTER (
        WHERE ome.event_type = 'bounced'
    ) AS bounced_count
FROM outbound_message om
LEFT JOIN outbound_message_event ome
    ON ome.outbound_message_id = om.id
SQL;

        if ($where !== []) {
            $sql .=
                "\nWHERE "
                . implode(
                    "\n  AND ",
                    $where,
                );
        }

        $sql .=
            <<<'SQL'

GROUP BY
    om.id,
    om.status,
    om.created_at,
    om.ready_for_submission_at,
    om.submitting_at,
    om.submission_uncertain_at,
    om.submitted_at
ORDER BY om.id DESC
SQL;

        $result =
            $this
                ->connection
                ->executeQuery(
                    $sql,
                    $parameters,
                    $types,
                );

        $rawRows = [];

        while (
            count($rawRows)
            < $limit + 1
            && ($row =
                $result->fetchAssociative())
                !== false
        ) {
            $rawRows[] = $row;
        }

        $hasMore =
            count($rawRows) > $limit;

        if ($hasMore) {
            array_pop(
                $rawRows,
            );
        }

        $items = array_map(
            static fn (
                array $row,
            ): array => [
                'messageId'
                    => (int) $row['id'],
                'status'
                    => (string) $row['status'],
                'createdAt'
                    => self::apiTimestamp(
                        (string) $row['created_at'],
                    ),
                'readyForSubmissionAt'
                    => self::nullableApiTimestamp(
                        $row['ready_for_submission_at'],
                    ),
                'submittingAt'
                    => self::nullableApiTimestamp(
                        $row['submitting_at'],
                    ),
                'submissionUncertainAt'
                    => self::nullableApiTimestamp(
                        $row['submission_uncertain_at'],
                    ),
                'submittedAt'
                    => self::nullableApiTimestamp(
                        $row['submitted_at'],
                    ),
                'deliverySummary' => [
                    'delivered'
                        => (int) $row['delivered_count'],
                    'tempfail'
                        => (int) $row['tempfail_count'],
                    'bounced'
                        => (int) $row['bounced_count'],
                ],
            ],
            $rawRows,
        );

        $nextCursor = null;

        if (
            $hasMore
            && $items !== []
        ) {
            $last =
                $items[
                    array_key_last(
                        $items,
                    )
                ];

            $nextCursor =
                $this
                    ->cursorCodec
                    ->encode(
                        $last['messageId'],
                    );
        }

        return [
            'items' => $items,
            'nextCursor' => $nextCursor,
        ];
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
                'Y-m-d H:i:s',
            );
    }

    private static function nullableApiTimestamp(
        mixed $value,
    ): ?string {
        if (
            $value === null
            || $value === ''
        ) {
            return null;
        }

        return self::apiTimestamp(
            (string) $value,
        );
    }

    private static function apiTimestamp(
        string $value,
    ): string {
        return (
            new DateTimeImmutable(
                $value,
                new DateTimeZone(
                    'UTC',
                ),
            )
        )
            ->setTimezone(
                new DateTimeZone(
                    'UTC',
                ),
            )
            ->format(
                DATE_ATOM,
            );
    }
}
