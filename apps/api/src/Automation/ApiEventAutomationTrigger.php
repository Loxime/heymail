<?php

declare(strict_types=1);

namespace App\Automation;

use App\Mail\EmailAddress;
use App\Template\EmailTemplateRenderer;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use JsonException;
use RuntimeException;

final readonly class ApiEventAutomationTrigger
{
    public function __construct(
        private Connection $connection,
        private EmailTemplateRenderer $renderer,
        private AutomationSnapshotCipher $snapshotCipher,
    ) {
    }

    /**
     * @param array<string, scalar|null> $variables
     *
     * @return array{
     *     eventId:int,
     *     matchedAutomations:int,
     *     replayed:bool
     * }
     */
    public function accept(
        int $workspaceId,
        string $apiKeyFingerprint,
        string $idempotencyKey,
        string $eventName,
        EmailAddress $recipient,
        array $variables,
    ): array {
        if ($workspaceId < 1) {
            throw new InvalidArgumentException(
                'Invalid automation event workspace.',
            );
        }

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

        self::assertIdempotencyKey(
            $idempotencyKey,
        );

        if (
            preg_match(
                '/^[a-z][a-z0-9_.-]{0,63}$/D',
                $eventName,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid automation event name.',
            );
        }

        $recipientEmail =
            strtolower(
                $recipient->email,
            );

        $normalizedVariables =
            self::normalizedVariables(
                $variables,
            );

        $requestHash =
            self::requestHash(
                $eventName,
                $recipientEmail,
                $recipient->name,
                $normalizedVariables,
            );

        $idempotencyHash =
            hash(
                'sha256',
                $idempotencyKey,
            );

        $lockKey =
            sprintf(
                'automation-api-event:%d:%s',
                $workspaceId,
                $idempotencyHash,
            );

        $this->connection->beginTransaction();

        try {
            $this
                ->connection
                ->executeQuery(
                    <<<'SQL'
SELECT pg_advisory_xact_lock(
    hashtextextended(:lock_key, 0)
)
SQL,
                    [
                        'lock_key'
                            => $lockKey,
                    ],
                );

            $existing =
                $this
                    ->connection
                    ->fetchAssociative(
                        <<<'SQL'
SELECT
    id,
    event_name,
    request_hash,
    matched_automation_count
FROM automation_api_event
WHERE workspace_id = :workspace_id
  AND idempotency_key_hash = :idempotency_key_hash
SQL,
                        [
                            'workspace_id'
                                => $workspaceId,
                            'idempotency_key_hash'
                                => $idempotencyHash,
                        ],
                    );

            if ($existing !== false) {
                if (
                    !hash_equals(
                        (string) $existing['request_hash'],
                        $requestHash,
                    )
                    || (string) $existing['event_name']
                        !== $eventName
                ) {
                    throw new AutomationApiEventConflictException(
                        'Idempotency key is already associated with another automation event.',
                    );
                }

                $eventId =
                    self::positiveId(
                        $existing['id']
                        ?? null,
                    );

                if ($eventId === null) {
                    throw new RuntimeException(
                        'Existing automation API event has an invalid identifier.',
                    );
                }

                $matched =
                    filter_var(
                        $existing['matched_automation_count']
                        ?? null,
                        FILTER_VALIDATE_INT,
                        [
                            'options' => [
                                'min_range' => 0,
                            ],
                        ],
                    );

                if (!is_int($matched)) {
                    throw new RuntimeException(
                        'Existing automation API event has an invalid match count.',
                    );
                }

                $this->connection->commit();

                return [
                    'eventId'
                        => $eventId,
                    'matchedAutomations'
                        => $matched,
                    'replayed'
                        => true,
                ];
            }

            $now = self::now();

            $eventId =
                self::positiveId(
                    $this
                        ->connection
                        ->fetchOne(
                            <<<'SQL'
INSERT INTO automation_api_event (
    workspace_id,
    api_key_fingerprint,
    idempotency_key_hash,
    event_name,
    request_hash,
    matched_automation_count,
    created_at
)
VALUES (
    :workspace_id,
    :api_key_fingerprint,
    :idempotency_key_hash,
    :event_name,
    :request_hash,
    0,
    :created_at
)
RETURNING id
SQL,
                            [
                                'workspace_id'
                                    => $workspaceId,
                                'api_key_fingerprint'
                                    => $apiKeyFingerprint,
                                'idempotency_key_hash'
                                    => $idempotencyHash,
                                'event_name'
                                    => $eventName,
                                'request_hash'
                                    => $requestHash,
                                'created_at'
                                    => $now->format(
                                        'Y-m-d H:i:s',
                                    ),
                            ],
                        ),
                );

            if ($eventId === null) {
                throw new RuntimeException(
                    'Automation API event identifier is invalid.',
                );
            }

            $automations =
                $this
                    ->connection
                    ->fetchAllAssociative(
                        <<<'SQL'
SELECT
    id,
    delay_seconds,
    sender_identity_id,
    template_id
FROM automation
WHERE workspace_id = :workspace_id
  AND trigger_type = 'api_event'
  AND trigger_event_name = :event_name
  AND status = 'active'
ORDER BY id
SQL,
                        [
                            'workspace_id'
                                => $workspaceId,
                            'event_name'
                                => $eventName,
                        ],
                    );

            $matched = 0;

            foreach ($automations as $automation) {
                ++$matched;

                $this->createJob(
                    $workspaceId,
                    $eventId,
                    $automation,
                    $recipientEmail,
                    $recipient->name,
                    $normalizedVariables,
                    $now,
                );
            }

            $changed =
                $this
                    ->connection
                    ->update(
                        'automation_api_event',
                        [
                            'matched_automation_count'
                                => $matched,
                        ],
                        [
                            'id'
                                => $eventId,
                            'workspace_id'
                                => $workspaceId,
                        ],
                    );

            if ($changed !== 1) {
                throw new RuntimeException(
                    'Automation API event match count was not persisted.',
                );
            }

            $this->connection->commit();

            return [
                'eventId'
                    => $eventId,
                'matchedAutomations'
                    => $matched,
                'replayed'
                    => false,
            ];
        } catch (\Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }
    }

    /**
     * @param array<string, mixed> $automation
     * @param array<string, scalar|null> $variables
     */
    private function createJob(
        int $workspaceId,
        int $eventId,
        array $automation,
        string $recipientEmail,
        ?string $recipientName,
        array $variables,
        DateTimeImmutable $now,
    ): void {
        $automationId =
            self::positiveId(
                $automation['id']
                ?? null,
            );

        $senderId =
            self::positiveId(
                $automation['sender_identity_id']
                ?? null,
            );

        $templateId =
            self::positiveId(
                $automation['template_id']
                ?? null,
            );

        $delay =
            filter_var(
                $automation['delay_seconds']
                ?? null,
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 0,
                        'max_range' => 31536000,
                    ],
                ],
            );

        if (
            $automationId === null
            || !is_int($delay)
        ) {
            throw new RuntimeException(
                'API-event automation definition is invalid.',
            );
        }

        $triggerKey =
            sprintf(
                'api-event:%d',
                $eventId,
            );

        $dueAt =
            $now->modify(
                sprintf(
                    '+%d seconds',
                    $delay,
                ),
            );

        if (
            $senderId === null
            || $templateId === null
        ) {
            $this->insertSkipped(
                $workspaceId,
                $automationId,
                $triggerKey,
                $dueAt,
                $now,
                'source_unavailable',
            );

            return;
        }

        $sender =
            $this
                ->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT s.email
FROM sender_identity s
INNER JOIN sending_domain d
    ON d.id = s.sending_domain_id
WHERE s.id = :sender_id
  AND d.workspace_id = :workspace_id
  AND d.status = 'verified'
  AND d.dkim_selector IS NOT NULL
  AND d.dkim_public_key IS NOT NULL
  AND d.dkim_provisioned_at IS NOT NULL
SQL,
                    [
                        'sender_id'
                            => $senderId,
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        $template =
            $this
                ->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT
    v.version,
    v.subject,
    v.text_body,
    v.html_body
FROM email_template t
INNER JOIN LATERAL (
    SELECT
        version,
        subject,
        text_body,
        html_body
    FROM email_template_version
    WHERE template_id = t.id
    ORDER BY version DESC
    LIMIT 1
) v ON TRUE
WHERE t.id = :template_id
  AND t.workspace_id = :workspace_id
SQL,
                    [
                        'template_id'
                            => $templateId,
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        if (
            $sender === false
            || $template === false
        ) {
            $this->insertSkipped(
                $workspaceId,
                $automationId,
                $triggerKey,
                $dueAt,
                $now,
                'source_unavailable',
            );

            return;
        }

        $requiredVariables = [];

        foreach (
            [
                (string) $template['subject'],
                is_string($template['text_body'])
                    ? $template['text_body']
                    : '',
                is_string($template['html_body'])
                    ? $template['html_body']
                    : '',
            ]
            as $part
        ) {
            $requiredVariables = [
                ...$requiredVariables,
                ...$this
                    ->renderer
                    ->variables(
                        $part,
                    ),
            ];
        }

        $requiredVariables =
            array_values(
                array_unique(
                    $requiredVariables,
                ),
            );

        sort(
            $requiredVariables,
            SORT_STRING,
        );

        $values = [
            ...$variables,
            'email'
                => $recipientEmail,
            'name'
                => $recipientName ?? '',
            'first_name'
                => self::firstName(
                    $recipientName,
                ),
        ];

        $selected = [];

        foreach ($requiredVariables as $variable) {
            if (
                !array_key_exists(
                    $variable,
                    $values,
                )
            ) {
                $this->insertSkipped(
                    $workspaceId,
                    $automationId,
                    $triggerKey,
                    $dueAt,
                    $now,
                    'missing_variable',
                );

                return;
            }

            $selected[$variable] =
                $values[$variable];
        }

        $jobId =
            self::positiveId(
                $this
                    ->connection
                    ->fetchOne(
                        <<<'SQL'
SELECT nextval(
    'automation_job_id_seq'
)
SQL
                    ),
            );

        if ($jobId === null) {
            throw new RuntimeException(
                'Automation job identifier is invalid.',
            );
        }

        $encrypted =
            $this
                ->snapshotCipher
                ->encrypt(
                    $workspaceId,
                    $jobId,
                    [
                        'sender' => [
                            'email'
                                => (string) $sender['email'],
                        ],
                        'template' => [
                            'version'
                                => (int) $template['version'],
                            'subject'
                                => (string) $template['subject'],
                            'text'
                                => $template['text_body']
                                    === null
                                    ? null
                                    : (string) $template['text_body'],
                            'html'
                                => $template['html_body']
                                    === null
                                    ? null
                                    : (string) $template['html_body'],
                        ],
                        'recipient' => [
                            'email'
                                => $recipientEmail,
                            'name'
                                => $recipientName,
                            'variables'
                                => $selected,
                        ],
                    ],
                );

        $this
            ->connection
            ->insert(
                'automation_job',
                [
                    'id'
                        => $jobId,
                    'automation_id'
                        => $automationId,
                    'workspace_id'
                        => $workspaceId,
                    'trigger_key'
                        => $triggerKey,
                    'status'
                        => 'pending',
                    'due_at'
                        => $dueAt->format(
                            'Y-m-d H:i:s',
                        ),
                    'snapshot_at'
                        => $now->format(
                            'Y-m-d H:i:s',
                        ),
                    'snapshot_ciphertext'
                        => $encrypted['ciphertext'],
                    'snapshot_nonce'
                        => $encrypted['nonce'],
                    'snapshot_wrapped_dek'
                        => $encrypted['wrappedDek'],
                    'snapshot_wrap_nonce'
                        => $encrypted['wrapNonce'],
                    'snapshot_algorithm'
                        => $encrypted['algorithm'],
                    'snapshot_key_version'
                        => $encrypted['keyVersion'],
                    'created_at'
                        => $now->format(
                            'Y-m-d H:i:s',
                        ),
                    'updated_at'
                        => $now->format(
                            'Y-m-d H:i:s',
                        ),
                ],
            );
    }

    private function insertSkipped(
        int $workspaceId,
        int $automationId,
        string $triggerKey,
        DateTimeImmutable $dueAt,
        DateTimeImmutable $now,
        string $reason,
    ): void {
        $this
            ->connection
            ->insert(
                'automation_job',
                [
                    'automation_id'
                        => $automationId,
                    'workspace_id'
                        => $workspaceId,
                    'trigger_key'
                        => $triggerKey,
                    'status'
                        => 'skipped',
                    'due_at'
                        => $dueAt->format(
                            'Y-m-d H:i:s',
                        ),
                    'skip_reason'
                        => $reason,
                    'completed_at'
                        => $now->format(
                            'Y-m-d H:i:s',
                        ),
                    'created_at'
                        => $now->format(
                            'Y-m-d H:i:s',
                        ),
                    'updated_at'
                        => $now->format(
                            'Y-m-d H:i:s',
                        ),
                ],
            );
    }

    /**
     * @param array<string, scalar|null> $variables
     *
     * @return array<string, scalar|null>
     */
    private static function normalizedVariables(
        array $variables,
    ): array {
        if (count($variables) > 64) {
            throw new InvalidArgumentException(
                'Automation event variables are limited to 64 entries.',
            );
        }

        $normalized = [];

        foreach ($variables as $name => $value) {
            if (
                !is_string($name)
                || preg_match(
                    '/^[a-z][a-z0-9_]{0,63}$/D',
                    $name,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'Invalid automation event variable name.',
                );
            }

            if (
                in_array(
                    $name,
                    [
                        'email',
                        'name',
                        'first_name',
                    ],
                    true,
                )
            ) {
                throw new InvalidArgumentException(
                    'Reserved recipient variables cannot be overridden.',
                );
            }

            if (
                $value !== null
                && !is_scalar($value)
            ) {
                throw new InvalidArgumentException(
                    'Automation event variable values must be scalar or null.',
                );
            }

            if (
                is_string($value)
                && strlen($value) > 8192
            ) {
                throw new InvalidArgumentException(
                    'Automation event string variable is too large.',
                );
            }

            $normalized[$name] =
                $value;
        }

        ksort(
            $normalized,
            SORT_STRING,
        );

        return $normalized;
    }

    /**
     * @param array<string, scalar|null> $variables
     */
    private static function requestHash(
        string $eventName,
        string $recipientEmail,
        ?string $recipientName,
        array $variables,
    ): string {
        try {
            $canonical =
                json_encode(
                    [
                        'eventName'
                            => $eventName,
                        'recipient' => [
                            'email'
                                => $recipientEmail,
                            'name'
                                => $recipientName,
                        ],
                        'variables'
                            => $variables,
                    ],
                    JSON_THROW_ON_ERROR
                    | JSON_UNESCAPED_SLASHES
                    | JSON_UNESCAPED_UNICODE,
                );
        } catch (JsonException $exception) {
            throw new InvalidArgumentException(
                'Automation event payload cannot be encoded.',
                0,
                $exception,
            );
        }

        return hash(
            'sha256',
            $canonical,
        );
    }

    private static function assertIdempotencyKey(
        string $idempotencyKey,
    ): void {
        $length =
            strlen(
                $idempotencyKey,
            );

        if (
            $length === 0
            || $length > 255
            || trim($idempotencyKey) === ''
            || preg_match(
                '/[\x00-\x1F\x7F]/',
                $idempotencyKey,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Invalid automation event idempotency key.',
            );
        }
    }

    private static function firstName(
        ?string $name,
    ): string {
        if (
            $name === null
            || trim($name) === ''
        ) {
            return '';
        }

        return preg_split(
            '/\s+/u',
            trim($name),
            2,
        )[0] ?? '';
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
