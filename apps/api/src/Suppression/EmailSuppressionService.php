<?php

declare(strict_types=1);

namespace App\Suppression;

use App\Mail\EmailAddress;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use RuntimeException;

final readonly class EmailSuppressionService
{
    public function __construct(
        private Connection $connection,
    ) {
    }

    /**
     * @return array{
     *     id:int,
     *     scope:string,
     *     reason:string
     * }|null
     */
    public function match(
        int $workspaceId,
        string $email,
        ?int $contactListId = null,
    ): ?array {
        if ($workspaceId < 1) {
            throw new InvalidArgumentException(
                'Invalid suppression workspace.',
            );
        }

        if (
            $contactListId !== null
            && $contactListId < 1
        ) {
            throw new InvalidArgumentException(
                'Invalid suppression list.',
            );
        }

        $normalized = self::normalizeEmail(
            $email,
        );

        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT
    id,
    scope,
    reason
FROM email_suppression
WHERE workspace_id = :workspace_id
  AND email_hash = :email_hash
  AND (
      scope = 'global'
      OR (
          scope = 'list'
          AND contact_list_id = :contact_list_id
      )
  )
ORDER BY
    CASE scope
        WHEN 'global' THEN 0
        ELSE 1
    END,
    id
LIMIT 1
SQL,
            [
                'workspace_id' => $workspaceId,
                'email_hash' => hash(
                    'sha256',
                    $normalized,
                ),
                'contact_list_id' => $contactListId,
            ],
        );

        if ($row === false) {
            return null;
        }

        $id = filter_var(
            $row['id'],
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        if (!is_int($id)) {
            throw new RuntimeException(
                'Invalid suppression identifier.',
            );
        }

        return [
            'id' => $id,
            'scope' => (string) $row['scope'],
            'reason' => (string) $row['reason'],
        ];
    }

    public function suppressGlobal(
        int $workspaceId,
        string $email,
        string $reason,
        ?int $sourceOutboundMessageId = null,
        ?string $sourceEventId = null,
    ): int {
        return $this->suppress(
            workspaceId: $workspaceId,
            email: $email,
            contactListId: null,
            reason: $reason,
            sourceOutboundMessageId:
                $sourceOutboundMessageId,
            sourceEventId:
                $sourceEventId,
        );
    }

    public function suppressList(
        int $workspaceId,
        int $contactListId,
        string $email,
        string $reason,
    ): int {
        if ($contactListId < 1) {
            throw new InvalidArgumentException(
                'Invalid suppression list.',
            );
        }

        return $this->suppress(
            workspaceId: $workspaceId,
            email: $email,
            contactListId: $contactListId,
            reason: $reason,
            sourceOutboundMessageId: null,
            sourceEventId: null,
        );
    }

    private function suppress(
        int $workspaceId,
        string $email,
        ?int $contactListId,
        string $reason,
        ?int $sourceOutboundMessageId,
        ?string $sourceEventId,
    ): int {
        if ($workspaceId < 1) {
            throw new InvalidArgumentException(
                'Invalid suppression workspace.',
            );
        }

        if (
            !in_array(
                $reason,
                [
                    'manual',
                    'hard_bounce',
                    'unsubscribe',
                ],
                true,
            )
        ) {
            throw new InvalidArgumentException(
                'Invalid suppression reason.',
            );
        }

        if (
            $sourceOutboundMessageId !== null
            && $sourceOutboundMessageId < 1
        ) {
            throw new InvalidArgumentException(
                'Invalid suppression source message.',
            );
        }

        if (
            $sourceEventId !== null
            && preg_match(
                '/^[a-f0-9]{64}$/D',
                $sourceEventId,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid suppression source event.',
            );
        }

        $normalized = self::normalizeEmail(
            $email,
        );

        $now = new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );

        $params = [
            'workspace_id' => $workspaceId,
            'contact_list_id' => $contactListId,
            'email' => $normalized,
            'email_hash' => hash(
                'sha256',
                $normalized,
            ),
            'scope' => $contactListId === null
                ? 'global'
                : 'list',
            'reason' => $reason,
            'source_outbound_message_id'
                => $sourceOutboundMessageId,
            'source_event_id'
                => $sourceEventId,
            'created_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
            'updated_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
        ];

        if ($contactListId === null) {
            $sql = <<<'SQL'
INSERT INTO email_suppression (
    workspace_id,
    contact_list_id,
    email,
    email_hash,
    scope,
    reason,
    source_outbound_message_id,
    source_event_id,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    NULL,
    :email,
    :email_hash,
    'global',
    :reason,
    :source_outbound_message_id,
    :source_event_id,
    :created_at,
    :updated_at
)
ON CONFLICT (
    workspace_id,
    email_hash
)
WHERE scope = 'global'
DO UPDATE SET
    email = EXCLUDED.email,
    reason = CASE
        WHEN email_suppression.reason = 'unsubscribe'
            THEN email_suppression.reason
        ELSE EXCLUDED.reason
    END,
    source_outbound_message_id =
        COALESCE(
            EXCLUDED.source_outbound_message_id,
            email_suppression.source_outbound_message_id
        ),
    source_event_id =
        COALESCE(
            EXCLUDED.source_event_id,
            email_suppression.source_event_id
        ),
    updated_at = EXCLUDED.updated_at
RETURNING id
SQL;
        } else {
            $sql = <<<'SQL'
INSERT INTO email_suppression (
    workspace_id,
    contact_list_id,
    email,
    email_hash,
    scope,
    reason,
    source_outbound_message_id,
    source_event_id,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :contact_list_id,
    :email,
    :email_hash,
    'list',
    :reason,
    NULL,
    NULL,
    :created_at,
    :updated_at
)
ON CONFLICT (
    workspace_id,
    contact_list_id,
    email_hash
)
WHERE scope = 'list'
DO UPDATE SET
    email = EXCLUDED.email,
    reason = CASE
        WHEN email_suppression.reason = 'unsubscribe'
            THEN email_suppression.reason
        ELSE EXCLUDED.reason
    END,
    updated_at = EXCLUDED.updated_at
RETURNING id
SQL;
        }

        $sqlParams = $params;

        unset(
            $sqlParams['scope'],
        );

        if ($contactListId === null) {
            unset(
                $sqlParams['contact_list_id'],
            );
        } else {
            unset(
                $sqlParams['source_outbound_message_id'],
                $sqlParams['source_event_id'],
            );
        }

        $id = filter_var(
            $this->connection->fetchOne(
                $sql,
                $sqlParams,
            ),
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        if (!is_int($id)) {
            throw new RuntimeException(
                'Suppression did not receive a valid identifier.',
            );
        }

        return $id;
    }

    private static function normalizeEmail(
        string $email,
    ): string {
        $email = trim(
            $email,
        );

        new EmailAddress(
            $email,
        );

        return strtolower(
            $email,
        );
    }
}
