<?php

declare(strict_types=1);

namespace App\Automation;

use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundMessageSubmissionService;
use App\Suppression\EmailSuppressionService;
use App\Suppression\UnsubscribeTokenCodec;
use App\Template\EmailTemplateRenderer;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use RuntimeException;

final readonly class AutomationJobProcessor
{
    public function __construct(
        private Connection $connection,
        private AutomationSnapshotCipher $snapshotCipher,
        private AutomationQuotaLimiter $quotaLimiter,
        private EmailTemplateRenderer $renderer,
        private OutboundMessageSubmissionService $submissionService,
        private EmailSuppressionService $suppressions,
        private UnsubscribeTokenCodec $unsubscribeTokens,
    ) {
    }

    public function processNextJob(): bool
    {
        $candidate =
            $this
                ->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT id
FROM automation_job
WHERE status = 'dispatching'
   OR (
       status = 'pending'
       AND due_at <= CURRENT_TIMESTAMP
   )
ORDER BY
    CASE
        WHEN status = 'dispatching' THEN 0
        ELSE 1
    END,
    due_at,
    id
LIMIT 1
SQL
                );

        if ($candidate === false) {
            return false;
        }

        $jobId =
            self::positiveId(
                $candidate['id']
                ?? null,
            );

        if ($jobId === null) {
            throw new RuntimeException(
                'Automation candidate identifier is invalid.',
            );
        }

        $locked =
            (bool) $this
                ->connection
                ->fetchOne(
                    <<<'SQL'
SELECT pg_try_advisory_lock(
    hashtextextended(:lock_key, 0)
)
SQL,
                    [
                        'lock_key'
                            => 'automation-job:'
                                . $jobId,
                    ],
                );

        if (!$locked) {
            return false;
        }

        try {
            return $this->processLocked(
                $jobId,
            );
        } finally {
            $this
                ->connection
                ->executeQuery(
                    <<<'SQL'
SELECT pg_advisory_unlock(
    hashtextextended(:lock_key, 0)
)
SQL,
                    [
                        'lock_key'
                            => 'automation-job:'
                                . $jobId,
                    ],
                );
        }
    }

    private function processLocked(
        int $jobId,
    ): bool {
        $row =
            $this
                ->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT *
FROM automation_job
WHERE id = :id
SQL,
                    [
                        'id' => $jobId,
                    ],
                );

        if ($row === false) {
            return false;
        }

        $status =
            (string) $row['status'];

        if (
            $status === 'completed'
            || $status === 'skipped'
        ) {
            return false;
        }

        if (
            !in_array(
                $status,
                [
                    'pending',
                    'dispatching',
                ],
                true,
            )
        ) {
            throw new RuntimeException(
                'Automation job status is invalid.',
            );
        }

        $workspaceId =
            self::positiveId(
                $row['workspace_id']
                ?? null,
            );

        if ($workspaceId === null) {
            throw new RuntimeException(
                'Automation job workspace is invalid.',
            );
        }

        $snapshot =
            $this
                ->snapshotCipher
                ->decrypt(
                    $workspaceId,
                    $jobId,
                    self::encrypted(
                        $row,
                    ),
                );

        [
            $senderEmail,
            $recipientEmail,
            $recipientName,
            $variables,
            $subjectTemplate,
            $textTemplate,
            $htmlTemplate,
        ] = self::snapshot(
            $snapshot,
        );

        if ($status === 'pending') {
            if (
                $this
                    ->suppressions
                    ->match(
                        $workspaceId,
                        $recipientEmail,
                        null,
                    )
                !== null
            ) {
                $this->markSkipped(
                    $jobId,
                    'suppressed',
                );

                return true;
            }

            $retryAfter =
                $this
                    ->quotaLimiter
                    ->reserve(
                        $workspaceId,
                        $jobId,
                    );

            if ($retryAfter !== null) {
                $now = self::now();

                $this
                    ->connection
                    ->update(
                        'automation_job',
                        [
                            'due_at'
                                => $now
                                    ->modify(
                                        sprintf(
                                            '+%d seconds',
                                            $retryAfter,
                                        ),
                                    )
                                    ->format(
                                        'Y-m-d H:i:s',
                                    ),
                            'last_error'
                                => sprintf(
                                    'Automation hourly quota exhausted; retry after %d seconds.',
                                    $retryAfter,
                                ),
                            'updated_at'
                                => $now->format(
                                    'Y-m-d H:i:s',
                                ),
                        ],
                        [
                            'id' => $jobId,
                            'status'
                                => 'pending',
                        ],
                    );

                return true;
            }

            $changed =
                $this
                    ->connection
                    ->update(
                        'automation_job',
                        [
                            'status'
                                => 'dispatching',
                            'last_error'
                                => null,
                            'updated_at'
                                => self::now()
                                    ->format(
                                        'Y-m-d H:i:s',
                                    ),
                        ],
                        [
                            'id' => $jobId,
                            'status'
                                => 'pending',
                        ],
                    );

            if ($changed !== 1) {
                throw new RuntimeException(
                    'Automation dispatch state changed unexpectedly.',
                );
            }
        }

        $unsubscribeUrl =
            $this
                ->unsubscribeTokens
                ->url(
                    $workspaceId,
                    null,
                    $recipientEmail,
                );

        $text =
            self::renderNullable(
                $this->renderer,
                $textTemplate,
                $variables,
            );

        $html =
            self::renderNullable(
                $this->renderer,
                $htmlTemplate,
                $variables,
            );

        if ($text !== null) {
            $text .= sprintf(
                "\n\nUnsubscribe: %s",
                $unsubscribeUrl,
            );
        }

        if ($html !== null) {
            $html .= sprintf(
                '<p style="font-size:12px;color:#667085"><a href="%s">Unsubscribe</a></p>',
                htmlspecialchars(
                    $unsubscribeUrl,
                    ENT_QUOTES
                    | ENT_SUBSTITUTE,
                    'UTF-8',
                ),
            );
        }

        $to = [
            'email'
                => $recipientEmail,
        ];

        if (
            $recipientName !== null
            && $recipientName !== ''
        ) {
            $to['name'] =
                $recipientName;
        }

        $payload =
            OutboundEmailPayload::fromArray(
                [
                    'from' => [
                        'email'
                            => $senderEmail,
                    ],
                    'to' => [
                        $to,
                    ],
                    'subject'
                        => $this
                            ->renderer
                            ->render(
                                $subjectTemplate,
                                $variables,
                            ),
                    'text'
                        => $text,
                    'html'
                        => $html,
                ],
            )
                ->withUnsubscribeUrl(
                    $unsubscribeUrl,
                );

        $submission =
            $this
                ->submissionService
                ->submit(
                    sprintf(
                        'automation-job:%d',
                        $jobId,
                    ),
                    $payload,
                    $workspaceId,
                );

        $now = self::now();

        $changed =
            $this
                ->connection
                ->update(
                    'automation_job',
                    [
                        'status'
                            => 'completed',
                        'outbound_message_id'
                            => $submission
                                ->messageId,
                        'completed_at'
                            => $now->format(
                                'Y-m-d H:i:s',
                            ),
                        'last_error'
                            => null,
                        'updated_at'
                            => $now->format(
                                'Y-m-d H:i:s',
                            ),
                    ],
                    [
                        'id' => $jobId,
                        'status'
                            => 'dispatching',
                    ],
                );

        if ($changed !== 1) {
            throw new RuntimeException(
                'Automation job completion state changed unexpectedly.',
            );
        }

        return true;
    }

    private function markSkipped(
        int $jobId,
        string $reason,
    ): void {
        $now = self::now();

        $changed =
            $this
                ->connection
                ->update(
                    'automation_job',
                    [
                        'status'
                            => 'skipped',
                        'skip_reason'
                            => $reason,
                        'completed_at'
                            => $now->format(
                                'Y-m-d H:i:s',
                            ),
                        'last_error'
                            => null,
                        'updated_at'
                            => $now->format(
                                'Y-m-d H:i:s',
                            ),
                    ],
                    [
                        'id' => $jobId,
                        'status'
                            => 'pending',
                    ],
                );

        if ($changed !== 1) {
            throw new RuntimeException(
                'Automation skip state changed unexpectedly.',
            );
        }
    }

    /**
     * @param array<string, mixed> $row
     *
     * @return array{
     *     ciphertext:string,
     *     nonce:string,
     *     wrappedDek:string,
     *     wrapNonce:string,
     *     algorithm:string,
     *     keyVersion:int
     * }
     */
    private static function encrypted(
        array $row,
    ): array {
        foreach (
            [
                'snapshot_ciphertext',
                'snapshot_nonce',
                'snapshot_wrapped_dek',
                'snapshot_wrap_nonce',
                'snapshot_algorithm',
            ]
            as $key
        ) {
            if (
                !is_string(
                    $row[$key]
                    ?? null,
                )
            ) {
                throw new RuntimeException(
                    'Automation snapshot is incomplete.',
                );
            }
        }

        $keyVersion =
            filter_var(
                $row['snapshot_key_version']
                ?? null,
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 1,
                    ],
                ],
            );

        if (!is_int($keyVersion)) {
            throw new RuntimeException(
                'Automation snapshot key version is invalid.',
            );
        }

        return [
            'ciphertext'
                => $row['snapshot_ciphertext'],
            'nonce'
                => $row['snapshot_nonce'],
            'wrappedDek'
                => $row['snapshot_wrapped_dek'],
            'wrapNonce'
                => $row['snapshot_wrap_nonce'],
            'algorithm'
                => $row['snapshot_algorithm'],
            'keyVersion'
                => $keyVersion,
        ];
    }

    /**
     * @param array<string, mixed> $snapshot
     *
     * @return array{
     *     0:string,
     *     1:string,
     *     2:string|null,
     *     3:array<string, scalar|null>,
     *     4:string,
     *     5:string|null,
     *     6:string|null
     * }
     */
    private static function snapshot(
        array $snapshot,
    ): array {
        $sender =
            $snapshot['sender']
            ?? null;

        $template =
            $snapshot['template']
            ?? null;

        $recipient =
            $snapshot['recipient']
            ?? null;

        if (
            !is_array($sender)
            || !is_array($template)
            || !is_array($recipient)
            || !is_string(
                $sender['email']
                ?? null,
            )
            || !is_string(
                $recipient['email']
                ?? null,
            )
            || !is_string(
                $template['subject']
                ?? null,
            )
        ) {
            throw new RuntimeException(
                'Automation snapshot structure is invalid.',
            );
        }

        $name =
            $recipient['name']
            ?? null;

        if (
            $name !== null
            && !is_string($name)
        ) {
            throw new RuntimeException(
                'Automation recipient name is invalid.',
            );
        }

        $variables =
            $recipient['variables']
            ?? null;

        if (
            !is_array($variables)
            || (
                $variables !== []
                && array_is_list(
                    $variables,
                )
            )
        ) {
            throw new RuntimeException(
                'Automation variables are invalid.',
            );
        }

        foreach ($variables as $value) {
            if (
                $value !== null
                && !is_scalar($value)
            ) {
                throw new RuntimeException(
                    'Automation variable value is invalid.',
                );
            }
        }

        $text =
            $template['text']
            ?? null;

        $html =
            $template['html']
            ?? null;

        if (
            $text !== null
            && !is_string($text)
        ) {
            throw new RuntimeException(
                'Automation text template is invalid.',
            );
        }

        if (
            $html !== null
            && !is_string($html)
        ) {
            throw new RuntimeException(
                'Automation HTML template is invalid.',
            );
        }

        return [
            $sender['email'],
            $recipient['email'],
            $name,
            $variables,
            $template['subject'],
            $text,
            $html,
        ];
    }

    /**
     * @param array<string, scalar|null> $variables
     */
    private static function renderNullable(
        EmailTemplateRenderer $renderer,
        ?string $template,
        array $variables,
    ): ?string {
        if ($template === null) {
            return null;
        }

        return $renderer->render(
            $template,
            $variables,
        );
    }

    private static function positiveId(
        mixed $value,
    ): ?int {
        $id = filter_var(
            $value,
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        return is_int($id)
            ? $id
            : null;
    }

    private static function now():
    DateTimeImmutable {
        return new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );
    }
}
