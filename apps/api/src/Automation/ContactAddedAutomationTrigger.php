<?php

declare(strict_types=1);

namespace App\Automation;

use App\Template\EmailTemplateRenderer;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use JsonException;
use RuntimeException;

final readonly class ContactAddedAutomationTrigger
{
    public function __construct(
        private Connection $connection,
        private EmailTemplateRenderer $renderer,
        private AutomationSnapshotCipher $snapshotCipher,
    ) {
    }

    public function enqueue(
        int $workspaceId,
        int $contactId,
    ): void {
        if (
            $workspaceId < 1
            || $contactId < 1
        ) {
            throw new RuntimeException(
                'Invalid contact automation trigger scope.',
            );
        }

        $contact =
            $this
                ->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT
    id,
    email,
    name,
    custom_fields
FROM contact
WHERE id = :contact_id
  AND workspace_id = :workspace_id
SQL,
                    [
                        'contact_id'
                            => $contactId,
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        if ($contact === false) {
            throw new RuntimeException(
                'Triggered contact was not found.',
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
  AND trigger_type = 'contact_added'
  AND status = 'active'
ORDER BY id
SQL,
                    [
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        if ($automations === []) {
            return;
        }

        $now = self::now();

        foreach ($automations as $automation) {
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
                    'Automation definition is invalid.',
                );
            }

            $triggerKey =
                sprintf(
                    'contact-added:%d',
                    $contactId,
                );

            if (
                $this->jobExists(
                    $automationId,
                    $triggerKey,
                )
            ) {
                continue;
            }

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

                continue;
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

                continue;
            }

            $variables = [];

            foreach (
                [
                    (string) $template['subject'],
                    is_string(
                        $template['text_body'],
                    )
                        ? $template['text_body']
                        : '',
                    is_string(
                        $template['html_body'],
                    )
                        ? $template['html_body']
                        : '',
                ]
                as $part
            ) {
                $variables = [
                    ...$variables,
                    ...$this
                        ->renderer
                        ->variables(
                            $part,
                        ),
                ];
            }

            $variables =
                array_values(
                    array_unique(
                        $variables,
                    ),
                );

            sort(
                $variables,
                SORT_STRING,
            );

            $custom =
                self::decodeObject(
                    $contact['custom_fields']
                    ?? '{}',
                );

            $name =
                $contact['name'] === null
                    ? null
                    : (string) $contact['name'];

            $values = [
                ...$custom,
                'email'
                    => (string) $contact['email'],
                'name'
                    => $name ?? '',
                'first_name'
                    => self::firstName(
                        $name,
                    ),
            ];

            $selected = [];
            $missing = false;

            foreach ($variables as $variable) {
                if (
                    !array_key_exists(
                        $variable,
                        $values,
                    )
                ) {
                    $missing = true;
                    break;
                }

                $selected[$variable] =
                    $values[$variable];
            }

            if ($missing) {
                $this->insertSkipped(
                    $workspaceId,
                    $automationId,
                    $triggerKey,
                    $dueAt,
                    $now,
                    'missing_variable',
                );

                continue;
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
                                    => (string) $contact['email'],
                                'name'
                                    => $name,
                                'variables'
                                    => $selected,
                            ],
                        ],
                    );

            $this
                ->connection
                ->executeStatement(
                    <<<'SQL'
INSERT INTO automation_job (
    id,
    automation_id,
    workspace_id,
    trigger_key,
    status,
    due_at,
    snapshot_at,
    snapshot_ciphertext,
    snapshot_nonce,
    snapshot_wrapped_dek,
    snapshot_wrap_nonce,
    snapshot_algorithm,
    snapshot_key_version,
    created_at,
    updated_at
)
VALUES (
    :id,
    :automation_id,
    :workspace_id,
    :trigger_key,
    'pending',
    :due_at,
    :snapshot_at,
    :snapshot_ciphertext,
    :snapshot_nonce,
    :snapshot_wrapped_dek,
    :snapshot_wrap_nonce,
    :snapshot_algorithm,
    :snapshot_key_version,
    :created_at,
    :updated_at
)
ON CONFLICT (
    automation_id,
    trigger_key
)
DO NOTHING
SQL,
                    [
                        'id'
                            => $jobId,
                        'automation_id'
                            => $automationId,
                        'workspace_id'
                            => $workspaceId,
                        'trigger_key'
                            => $triggerKey,
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
    }

    private function jobExists(
        int $automationId,
        string $triggerKey,
    ): bool {
        return (int) $this
            ->connection
            ->fetchOne(
                <<<'SQL'
SELECT COUNT(*)
FROM automation_job
WHERE automation_id = :automation_id
  AND trigger_key = :trigger_key
SQL,
                [
                    'automation_id'
                        => $automationId,
                    'trigger_key'
                        => $triggerKey,
                ],
            ) === 1;
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
            ->executeStatement(
                <<<'SQL'
INSERT INTO automation_job (
    automation_id,
    workspace_id,
    trigger_key,
    status,
    due_at,
    skip_reason,
    completed_at,
    created_at,
    updated_at
)
VALUES (
    :automation_id,
    :workspace_id,
    :trigger_key,
    'skipped',
    :due_at,
    :skip_reason,
    :completed_at,
    :created_at,
    :updated_at
)
ON CONFLICT (
    automation_id,
    trigger_key
)
DO NOTHING
SQL,
                [
                    'automation_id'
                        => $automationId,
                    'workspace_id'
                        => $workspaceId,
                    'trigger_key'
                        => $triggerKey,
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
     * @return array<string, scalar|null>
     */
    private static function decodeObject(
        mixed $value,
    ): array {
        try {
            $decoded =
                is_array($value)
                    ? $value
                    : (
                        is_string($value)
                            ? json_decode(
                                $value,
                                true,
                                32,
                                JSON_THROW_ON_ERROR,
                            )
                            : null
                    );
        } catch (JsonException $exception) {
            throw new RuntimeException(
                'Contact custom fields are invalid.',
                0,
                $exception,
            );
        }

        if (
            !is_array($decoded)
            || (
                $decoded !== []
                && array_is_list(
                    $decoded,
                )
            )
        ) {
            throw new RuntimeException(
                'Contact custom fields are invalid.',
            );
        }

        foreach ($decoded as $item) {
            if (
                $item !== null
                && !is_scalar(
                    $item,
                )
            ) {
                throw new RuntimeException(
                    'Contact custom field value is invalid.',
                );
            }
        }

        return $decoded;
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
