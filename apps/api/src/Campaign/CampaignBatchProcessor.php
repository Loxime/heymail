<?php

declare(strict_types=1);

namespace App\Campaign;

use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundMessageSubmissionService;
use App\Template\EmailTemplateRenderer;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use RuntimeException;

final readonly class CampaignBatchProcessor
{
    private const int BATCH_SIZE = 25;

    public function __construct(
        private Connection $connection,
        private CampaignSnapshotCipher $snapshotCipher,
        private CampaignQuotaLimiter $quotaLimiter,
        private EmailTemplateRenderer $renderer,
        private OutboundMessageSubmissionService $submissionService,
    ) {
    }

    public function processNextBatch(): bool
    {
        $candidate = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT id
FROM campaign
WHERE (
    status = 'ready'
    OR status = 'processing'
    OR (
        status = 'scheduled'
        AND scheduled_for <= CURRENT_TIMESTAMP
    )
)
ORDER BY
    COALESCE(scheduled_for, created_at),
    id
LIMIT 1
SQL
        );

        if ($candidate === false) {
            return false;
        }

        $campaignId = (int) $candidate['id'];

        $locked = (bool) $this->connection->fetchOne(
            <<<'SQL'
SELECT pg_try_advisory_lock(
    hashtextextended(:lock_key, 0)
)
SQL,
            [
                'lock_key' => 'campaign:' . $campaignId,
            ],
        );

        if (!$locked) {
            return false;
        }

        try {
            return $this->processLocked(
                $campaignId,
            );
        } finally {
            $this->connection->executeQuery(
                <<<'SQL'
SELECT pg_advisory_unlock(
    hashtextextended(:lock_key, 0)
)
SQL,
                [
                    'lock_key' => 'campaign:' . $campaignId,
                ],
            );
        }
    }

    private function processLocked(
        int $campaignId,
    ): bool {
        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT *
FROM campaign
WHERE id = :id
SQL,
            [
                'id' => $campaignId,
            ],
        );

        if ($row === false) {
            return false;
        }

        $status = (string) $row['status'];

        if (
            $status === 'paused'
            || $status === 'cancelled'
            || $status === 'completed'
            || $status === 'draft'
        ) {
            return false;
        }

        $now = self::now();

        if (
            $status === 'scheduled'
            && (
                !is_string($row['scheduled_for'])
                || new DateTimeImmutable(
                    $row['scheduled_for'],
                    new DateTimeZone('UTC'),
                ) > $now
            )
        ) {
            return false;
        }

        $workspaceId = (int) $row['workspace_id'];
        $recipientCount = (int) $row['recipient_count'];
        $processedCount = (int) $row['processed_count'];

        if ($processedCount >= $recipientCount) {
            $this->markCompleted(
                $campaignId,
                $recipientCount,
            );
            return true;
        }

        if (
            !is_string($row['snapshot_ciphertext'])
            || !is_string($row['snapshot_nonce'])
            || !is_string($row['snapshot_wrapped_dek'])
            || !is_string($row['snapshot_wrap_nonce'])
            || !is_string($row['snapshot_algorithm'])
        ) {
            throw new RuntimeException(
                'Campaign snapshot is incomplete.',
            );
        }

        $snapshot = $this->snapshotCipher->decrypt(
            $workspaceId,
            $campaignId,
            [
                'ciphertext' => $row['snapshot_ciphertext'],
                'nonce' => $row['snapshot_nonce'],
                'wrappedDek' => $row['snapshot_wrapped_dek'],
                'wrapNonce' => $row['snapshot_wrap_nonce'],
                'algorithm' => $row['snapshot_algorithm'],
                'keyVersion' => (int) $row['snapshot_key_version'],
            ],
        );

        $recipients = $snapshot['recipients'] ?? null;
        $template = $snapshot['template'] ?? null;
        $sender = $snapshot['sender'] ?? null;

        if (
            !is_array($recipients)
            || !array_is_list($recipients)
            || count($recipients) !== $recipientCount
            || !is_array($template)
            || !is_array($sender)
            || !is_string($sender['email'] ?? null)
        ) {
            throw new RuntimeException(
                'Campaign snapshot structure is invalid.',
            );
        }

        $end = min(
            $recipientCount,
            $processedCount + self::BATCH_SIZE,
        );

        $indexes = range(
            $processedCount,
            $end - 1,
        );

        $reservation = $this->quotaLimiter->reserve(
            $workspaceId,
            $campaignId,
            $indexes,
        );

        if ($reservation['indexes'] === []) {
            $this->connection->update(
                'campaign',
                [
                    'status' => 'ready',
                    'last_error' => sprintf(
                        'Campaign hourly quota exhausted; retry after %d seconds.',
                        $reservation['retryAfter'] ?? 1,
                    ),
                    'updated_at' => $now->format('Y-m-d H:i:s'),
                ],
                ['id' => $campaignId],
            );

            return true;
        }

        $this->connection->update(
            'campaign',
            [
                'status' => 'processing',
                'last_error' => null,
                'updated_at' => $now->format('Y-m-d H:i:s'),
            ],
            ['id' => $campaignId],
        );

        foreach ($reservation['indexes'] as $index) {
            $currentStatus = (string) $this->connection->fetchOne(
                'SELECT status FROM campaign WHERE id = :id',
                ['id' => $campaignId],
            );

            if (
                $currentStatus === 'paused'
                || $currentStatus === 'cancelled'
            ) {
                return true;
            }

            $recipient = $recipients[$index] ?? null;

            if (!is_array($recipient)) {
                throw new RuntimeException(
                    'Campaign recipient snapshot is invalid.',
                );
            }

            $variables = $recipient['variables'] ?? null;

            if (
                !is_array($variables)
                || ($variables !== [] && array_is_list($variables))
                || !is_string($recipient['email'] ?? null)
            ) {
                throw new RuntimeException(
                    'Campaign recipient variables are invalid.',
                );
            }

            $payload = OutboundEmailPayload::fromArray([
                'from' => [
                    'email' => $sender['email'],
                ],
                'to' => [
                    array_filter(
                        [
                            'email' => $recipient['email'],
                            'name' => is_string($recipient['name'] ?? null)
                                && $recipient['name'] !== ''
                                ? $recipient['name']
                                : null,
                        ],
                        static fn (mixed $value): bool => $value !== null,
                    ),
                ],
                'subject' => $this->renderer->render(
                    self::requiredString(
                        $template,
                        'subject',
                    ),
                    $variables,
                ),
                'text' => self::renderNullable(
                    $this->renderer,
                    $template['text'] ?? null,
                    $variables,
                ),
                'html' => self::renderNullable(
                    $this->renderer,
                    $template['html'] ?? null,
                    $variables,
                ),
            ]);

            $submission = $this->submissionService->submit(
                sprintf(
                    'campaign:%d:recipient:%d',
                    $campaignId,
                    $index,
                ),
                $payload,
                $workspaceId,
            );

            $this->connection->executeStatement(
                <<<'SQL'
INSERT INTO campaign_delivery (
    campaign_id,
    recipient_index,
    outbound_message_id,
    created_at
)
VALUES (
    :campaign_id,
    :recipient_index,
    :outbound_message_id,
    :created_at
)
ON CONFLICT (
    campaign_id,
    recipient_index
)
DO UPDATE SET
    outbound_message_id = EXCLUDED.outbound_message_id
SQL,
                [
                    'campaign_id' => $campaignId,
                    'recipient_index' => $index,
                    'outbound_message_id' => $submission->messageId,
                    'created_at' => self::now()->format('Y-m-d H:i:s'),
                ],
            );

            $newProcessed = $index + 1;

            $this->connection->update(
                'campaign',
                [
                    'processed_count' => $newProcessed,
                    'updated_at' => self::now()->format('Y-m-d H:i:s'),
                ],
                ['id' => $campaignId],
            );
        }

        $finalState = $this->connection->fetchAssociative(
            'SELECT status, processed_count FROM campaign WHERE id = :id',
            ['id' => $campaignId],
        );

        if ($finalState === false) {
            throw new RuntimeException(
                'Campaign disappeared during batch processing.',
            );
        }

        $processed = (int) $finalState['processed_count'];
        $finalStatus = (string) $finalState['status'];

        if (
            $finalStatus === 'paused'
            || $finalStatus === 'cancelled'
        ) {
            return true;
        }

        if ($processed >= $recipientCount) {
            $this->markCompleted(
                $campaignId,
                $recipientCount,
            );
        } else {
            $this->connection->update(
                'campaign',
                [
                    'status' => 'ready',
                    'last_error' => $reservation['retryAfter'] === null
                        ? null
                        : sprintf(
                            'Campaign hourly quota partially exhausted; retry after %d seconds.',
                            $reservation['retryAfter'],
                        ),
                    'updated_at' => self::now()->format('Y-m-d H:i:s'),
                ],
                ['id' => $campaignId],
            );
        }

        return true;
    }

    private function markCompleted(
        int $campaignId,
        int $recipientCount,
    ): void {
        $now = self::now()->format('Y-m-d H:i:s');

        $this->connection->update(
            'campaign',
            [
                'status' => 'completed',
                'processed_count' => $recipientCount,
                'completed_at' => $now,
                'last_error' => null,
                'updated_at' => $now,
            ],
            ['id' => $campaignId],
        );
    }

    /**
     * @param array<string, mixed> $source
     */
    private static function requiredString(
        array $source,
        string $key,
    ): string {
        $value = $source[$key] ?? null;

        if (!is_string($value)) {
            throw new RuntimeException(
                sprintf(
                    'Campaign template %s is invalid.',
                    $key,
                ),
            );
        }

        return $value;
    }

    /**
     * @param array<string, scalar|null> $variables
     */
    private static function renderNullable(
        EmailTemplateRenderer $renderer,
        mixed $template,
        array $variables,
    ): ?string {
        if ($template === null) {
            return null;
        }

        if (!is_string($template)) {
            throw new RuntimeException(
                'Campaign template body is invalid.',
            );
        }

        return $renderer->render(
            $template,
            $variables,
        );
    }

    private static function now(): DateTimeImmutable
    {
        return new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );
    }
}
