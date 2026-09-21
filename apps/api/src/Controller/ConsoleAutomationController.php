<?php

declare(strict_types=1);

namespace App\Controller;

use App\Console\ConsoleAuthentication;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception\UniqueConstraintViolationException;
use InvalidArgumentException;
use JsonException;
use RuntimeException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/console/automations')]
final readonly class ConsoleAutomationController
{
    private const int MAX_REQUEST_BYTES = 8192;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
    ) {
    }

    #[Route(
        '',
        name: 'console_automations_list',
        methods: ['GET'],
    )]
    public function list(
        Request $request,
    ): JsonResponse {
        $workspaceId =
            $this->workspaceId(
                $request,
            );

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $rows =
            $this
                ->connection
                ->fetchAllAssociative(
                    <<<'SQL'
SELECT
    a.id,
    a.name,
    a.trigger_type,
    a.trigger_event_name,
    a.delay_seconds,
    a.sender_identity_id,
    a.template_id,
    a.status,
    a.created_at,
    a.updated_at,
    s.email AS sender_email,
    t.name AS template_name,
    (
        SELECT COUNT(*)
        FROM automation_job j
        WHERE j.automation_id = a.id
    ) AS job_count
FROM automation a
LEFT JOIN sender_identity s
    ON s.id = a.sender_identity_id
LEFT JOIN email_template t
    ON t.id = a.template_id
WHERE a.workspace_id = :workspace_id
ORDER BY a.id DESC
SQL,
                    [
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        return new JsonResponse([
            'items'
                => array_map(
                    self::serialize(...),
                    $rows,
                ),
        ]);
    }

    #[Route(
        '',
        name: 'console_automations_create',
        methods: ['POST'],
    )]
    public function create(
        Request $request,
    ): JsonResponse {
        $workspaceId =
            $this->workspaceId(
                $request,
            );

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $payload =
            self::jsonObject(
                $request,
            );

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        if (
            array_keys($payload)
            !== [
                'name',
                'triggerType',
                'eventName',
                'delaySeconds',
                'senderId',
                'templateId',
            ]
        ) {
            return self::error(
                'invalid_automation',
                'Expected name, triggerType, eventName, delaySeconds, senderId and templateId.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $name =
                self::name(
                    $payload['name'],
                );

            $triggerType =
                self::triggerType(
                    $payload['triggerType'],
                );

            $eventName =
                self::eventName(
                    $triggerType,
                    $payload['eventName'],
                );

            $delaySeconds =
                self::delaySeconds(
                    $payload['delaySeconds'],
                );

            $senderId =
                self::requiredId(
                    $payload['senderId'],
                    'senderId',
                );

            $templateId =
                self::requiredId(
                    $payload['templateId'],
                    'templateId',
                );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_automation',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        if (
            !$this->senderAuthorized(
                $workspaceId,
                $senderId,
            )
        ) {
            return self::error(
                'sender_not_authorized',
                'Automation sender must be an authorized workspace sender.',
                Response::HTTP_FORBIDDEN,
            );
        }

        if (
            !$this->templateOwned(
                $workspaceId,
                $templateId,
            )
        ) {
            return self::error(
                'template_not_found',
                'Automation template was not found.',
                Response::HTTP_NOT_FOUND,
            );
        }

        $now =
            self::now()
                ->format(
                    'Y-m-d H:i:s',
                );

        try {
            $automationId =
                self::positiveId(
                    $this
                        ->connection
                        ->fetchOne(
                            <<<'SQL'
INSERT INTO automation (
    workspace_id,
    name,
    trigger_type,
    trigger_event_name,
    delay_seconds,
    sender_identity_id,
    template_id,
    status,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    :trigger_type,
    :trigger_event_name,
    :delay_seconds,
    :sender_identity_id,
    :template_id,
    'active',
    :created_at,
    :updated_at
)
RETURNING id
SQL,
                            [
                                'workspace_id'
                                    => $workspaceId,
                                'name'
                                    => $name,
                                'trigger_type'
                                    => $triggerType,
                                'trigger_event_name'
                                    => $eventName,
                                'delay_seconds'
                                    => $delaySeconds,
                                'sender_identity_id'
                                    => $senderId,
                                'template_id'
                                    => $templateId,
                                'created_at'
                                    => $now,
                                'updated_at'
                                    => $now,
                            ],
                        ),
                );
        } catch (UniqueConstraintViolationException) {
            return self::error(
                'automation_conflict',
                'An automation with this name already exists in the workspace.',
                Response::HTTP_CONFLICT,
            );
        }

        if ($automationId === null) {
            throw new RuntimeException(
                'Automation identifier is invalid.',
            );
        }

        return new JsonResponse(
            $this->automationById(
                $workspaceId,
                $automationId,
            ),
            Response::HTTP_CREATED,
        );
    }

    #[Route(
        '/{id}/pause',
        name: 'console_automations_pause',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['POST'],
    )]
    public function pause(
        Request $request,
        string $id,
    ): JsonResponse {
        return $this->setStatus(
            $request,
            $id,
            'paused',
        );
    }

    #[Route(
        '/{id}/resume',
        name: 'console_automations_resume',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['POST'],
    )]
    public function resume(
        Request $request,
        string $id,
    ): JsonResponse {
        return $this->setStatus(
            $request,
            $id,
            'active',
        );
    }

    #[Route(
        '/{id}',
        name: 'console_automations_delete',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['DELETE'],
    )]
    public function delete(
        Request $request,
        string $id,
    ): Response {
        $workspaceId =
            $this->workspaceId(
                $request,
            );

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $automationId =
            self::positiveId(
                $id,
            );

        if ($automationId === null) {
            return self::notFound();
        }

        $row =
            $this
                ->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT
    id,
    (
        SELECT COUNT(*)
        FROM automation_job j
        WHERE j.automation_id = a.id
    ) AS job_count
FROM automation a
WHERE a.id = :id
  AND a.workspace_id = :workspace_id
SQL,
                    [
                        'id'
                            => $automationId,
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        if ($row === false) {
            return self::notFound();
        }

        if ((int) $row['job_count'] > 0) {
            return self::error(
                'automation_has_history',
                'Automation with execution history cannot be deleted; pause it instead.',
                Response::HTTP_CONFLICT,
            );
        }

        $deleted =
            $this
                ->connection
                ->delete(
                    'automation',
                    [
                        'id'
                            => $automationId,
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        if ($deleted !== 1) {
            return self::notFound();
        }

        return new Response(
            '',
            Response::HTTP_NO_CONTENT,
        );
    }

    private function setStatus(
        Request $request,
        string $id,
        string $status,
    ): JsonResponse {
        $workspaceId =
            $this->workspaceId(
                $request,
            );

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $automationId =
            self::positiveId(
                $id,
            );

        if ($automationId === null) {
            return self::notFound();
        }

        $changed =
            $this
                ->connection
                ->executeStatement(
                    <<<'SQL'
UPDATE automation
SET
    status = :status,
    updated_at = :updated_at
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
                    [
                        'status'
                            => $status,
                        'updated_at'
                            => self::now()
                                ->format(
                                    'Y-m-d H:i:s',
                                ),
                        'id'
                            => $automationId,
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        if ($changed !== 1) {
            return self::notFound();
        }

        return new JsonResponse(
            $this->automationById(
                $workspaceId,
                $automationId,
            ),
        );
    }

    /**
     * @return array<string, mixed>
     */
    private function automationById(
        int $workspaceId,
        int $automationId,
    ): array {
        $row =
            $this
                ->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT
    a.id,
    a.name,
    a.trigger_type,
    a.trigger_event_name,
    a.delay_seconds,
    a.sender_identity_id,
    a.template_id,
    a.status,
    a.created_at,
    a.updated_at,
    s.email AS sender_email,
    t.name AS template_name,
    (
        SELECT COUNT(*)
        FROM automation_job j
        WHERE j.automation_id = a.id
    ) AS job_count
FROM automation a
LEFT JOIN sender_identity s
    ON s.id = a.sender_identity_id
LEFT JOIN email_template t
    ON t.id = a.template_id
WHERE a.id = :id
  AND a.workspace_id = :workspace_id
SQL,
                    [
                        'id'
                            => $automationId,
                        'workspace_id'
                            => $workspaceId,
                    ],
                );

        if ($row === false) {
            throw new RuntimeException(
                'Created automation cannot be read.',
            );
        }

        return self::serialize(
            $row,
        );
    }

    /**
     * @param array<string, mixed> $row
     *
     * @return array<string, mixed>
     */
    private static function serialize(
        array $row,
    ): array {
        $id =
            self::positiveId(
                $row['id']
                ?? null,
            );

        $delay =
            filter_var(
                $row['delay_seconds']
                ?? null,
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 0,
                        'max_range' => 31536000,
                    ],
                ],
            );

        $jobCount =
            filter_var(
                $row['job_count']
                ?? null,
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 0,
                    ],
                ],
            );

        if (
            $id === null
            || !is_int($delay)
            || !is_int($jobCount)
            || !is_string(
                $row['name']
                ?? null,
            )
            || !is_string(
                $row['trigger_type']
                ?? null,
            )
            || !is_string(
                $row['status']
                ?? null,
            )
        ) {
            throw new RuntimeException(
                'Automation row is invalid.',
            );
        }

        $senderId =
            self::positiveId(
                $row['sender_identity_id']
                ?? null,
            );

        $templateId =
            self::positiveId(
                $row['template_id']
                ?? null,
            );

        return [
            'id'
                => $id,
            'name'
                => $row['name'],
            'triggerType'
                => $row['trigger_type'],
            'eventName'
                => is_string(
                    $row['trigger_event_name']
                    ?? null,
                )
                    ? $row['trigger_event_name']
                    : null,
            'delaySeconds'
                => $delay,
            'senderId'
                => $senderId,
            'senderEmail'
                => is_string(
                    $row['sender_email']
                    ?? null,
                )
                    ? $row['sender_email']
                    : null,
            'templateId'
                => $templateId,
            'templateName'
                => is_string(
                    $row['template_name']
                    ?? null,
                )
                    ? $row['template_name']
                    : null,
            'status'
                => $row['status'],
            'jobCount'
                => $jobCount,
            'createdAt'
                => self::timestamp(
                    $row['created_at']
                    ?? null,
                ),
            'updatedAt'
                => self::timestamp(
                    $row['updated_at']
                    ?? null,
                ),
        ];
    }

    private function workspaceId(
        Request $request,
    ): int|JsonResponse {
        $user =
            $this
                ->authentication
                ->authenticate(
                    $request,
                );

        if ($user === null) {
            return self::error(
                'console_unauthorized',
                'Console authentication required.',
                Response::HTTP_UNAUTHORIZED,
            );
        }

        $ids =
            $this
                ->connection
                ->fetchFirstColumn(
                    <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
ORDER BY workspace_id
LIMIT 2
SQL,
                    [
                        'user_id'
                            => $user['id'],
                    ],
                );

        if (count($ids) !== 1) {
            throw new RuntimeException(
                'Expected exactly one console workspace membership.',
            );
        }

        $workspaceId =
            self::positiveId(
                $ids[0],
            );

        if ($workspaceId === null) {
            throw new RuntimeException(
                'Console workspace identifier is invalid.',
            );
        }

        return $workspaceId;
    }

    private function senderAuthorized(
        int $workspaceId,
        int $senderId,
    ): bool {
        return (int) $this
            ->connection
            ->fetchOne(
                <<<'SQL'
SELECT COUNT(*)
FROM sender_identity s
INNER JOIN sending_domain d
    ON d.id = s.sending_domain_id
WHERE s.id = :id
  AND d.workspace_id = :workspace_id
  AND d.status = 'verified'
  AND d.dkim_selector IS NOT NULL
  AND d.dkim_public_key IS NOT NULL
  AND d.dkim_provisioned_at IS NOT NULL
SQL,
                [
                    'id'
                        => $senderId,
                    'workspace_id'
                        => $workspaceId,
                ],
            ) === 1;
    }

    private function templateOwned(
        int $workspaceId,
        int $templateId,
    ): bool {
        return (int) $this
            ->connection
            ->fetchOne(
                <<<'SQL'
SELECT COUNT(*)
FROM email_template
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
                [
                    'id'
                        => $templateId,
                    'workspace_id'
                        => $workspaceId,
                ],
            ) === 1;
    }

    private static function name(
        mixed $value,
    ): string {
        if (!is_string($value)) {
            throw new InvalidArgumentException(
                'Automation name is required.',
            );
        }

        $value =
            trim(
                $value,
            );

        if (
            $value === ''
            || strlen($value) > 160
            || preg_match(
                '/[\x00-\x1F\x7F]/',
                $value,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Automation name must contain between 1 and 160 printable characters.',
            );
        }

        return $value;
    }

    private static function triggerType(
        mixed $value,
    ): string {
        if (
            !is_string($value)
            || !in_array(
                $value,
                [
                    'contact_added',
                    'api_event',
                ],
                true,
            )
        ) {
            throw new InvalidArgumentException(
                'triggerType must be contact_added or api_event.',
            );
        }

        return $value;
    }

    private static function eventName(
        string $triggerType,
        mixed $value,
    ): ?string {
        if ($triggerType === 'contact_added') {
            if ($value !== null) {
                throw new InvalidArgumentException(
                    'eventName must be null for contact_added automations.',
                );
            }

            return null;
        }

        if (
            !is_string($value)
            || preg_match(
                '/^[a-z][a-z0-9_.-]{0,63}$/D',
                $value,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'eventName must match ^[a-z][a-z0-9_.-]{0,63}$.',
            );
        }

        return $value;
    }

    private static function delaySeconds(
        mixed $value,
    ): int {
        $delay =
            filter_var(
                $value,
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 0,
                        'max_range' => 31536000,
                    ],
                ],
            );

        if (!is_int($delay)) {
            throw new InvalidArgumentException(
                'delaySeconds must be between 0 and 31536000.',
            );
        }

        return $delay;
    }

    private static function requiredId(
        mixed $value,
        string $name,
    ): int {
        $id =
            self::positiveId(
                $value,
            );

        if ($id === null) {
            throw new InvalidArgumentException(
                sprintf(
                    '%s must be a positive identifier.',
                    $name,
                ),
            );
        }

        return $id;
    }

    /**
     * @return array<string, mixed>|JsonResponse
     */
    private static function jsonObject(
        Request $request,
    ): array|JsonResponse {
        if (
            $request->getContentTypeFormat()
            !== 'json'
        ) {
            return self::error(
                'unsupported_media_type',
                'Content-Type must be application/json.',
                Response::HTTP_UNSUPPORTED_MEDIA_TYPE,
            );
        }

        $raw =
            $request
                ->getContent();

        if (
            $raw === ''
            || strlen($raw)
                > self::MAX_REQUEST_BYTES
        ) {
            return self::error(
                'invalid_payload',
                'Automation request body must contain between 1 and 8192 bytes.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $payload =
                json_decode(
                    $raw,
                    true,
                    8,
                    JSON_THROW_ON_ERROR,
                );
        } catch (JsonException) {
            return self::error(
                'invalid_json',
                'Request body must contain valid JSON.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        if (
            !is_array($payload)
            || array_is_list($payload)
        ) {
            return self::error(
                'invalid_payload',
                'Request body must contain a JSON object.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        return $payload;
    }

    private static function positiveId(
        mixed $value,
    ): ?int {
        $id =
            filter_var(
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

    private static function timestamp(
        mixed $value,
    ): string {
        if (!is_string($value)) {
            throw new RuntimeException(
                'Automation timestamp is invalid.',
            );
        }

        return (
            new DateTimeImmutable(
                $value,
                new DateTimeZone('UTC'),
            )
        )
            ->format(
                DATE_ATOM,
            );
    }

    private static function notFound():
    JsonResponse {
        return self::error(
            'automation_not_found',
            'Automation was not found.',
            Response::HTTP_NOT_FOUND,
        );
    }

    private static function error(
        string $code,
        string $message,
        int $status,
    ): JsonResponse {
        return new JsonResponse(
            [
                'error' => [
                    'code'
                        => $code,
                    'message'
                        => $message,
                ],
            ],
            $status,
        );
    }

    private static function now():
    DateTimeImmutable {
        return new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );
    }
}
