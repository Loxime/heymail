<?php

declare(strict_types=1);

namespace App\Controller;

use App\Console\ConsoleAuthentication;
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundMessageSubmissionService;
use App\Template\EmailTemplateRenderer;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use JsonException;
use RuntimeException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/console/campaigns')]
final readonly class ConsoleCampaignExecutionController
{
    private const int MAX_REQUEST_BYTES = 65536;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
        private EmailTemplateRenderer $renderer,
        private OutboundMessageSubmissionService $submissionService,
    ) {
    }

    #[Route(
        '/{id}/pause',
        name: 'console_campaigns_pause',
        requirements: ['id' => '[1-9][0-9]*'],
        methods: ['POST'],
    )]
    public function pause(
        Request $request,
        string $id,
    ): JsonResponse {
        return $this->transition(
            $request,
            $id,
            ['scheduled', 'ready', 'processing'],
            'paused',
        );
    }

    #[Route(
        '/{id}/resume',
        name: 'console_campaigns_resume',
        requirements: ['id' => '[1-9][0-9]*'],
        methods: ['POST'],
    )]
    public function resume(
        Request $request,
        string $id,
    ): JsonResponse {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $campaignId = self::positiveId($id);

        if ($campaignId === null) {
            return self::notFound();
        }

        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT status, scheduled_for
FROM campaign
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
            [
                'id' => $campaignId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($row === false) {
            return self::notFound();
        }

        if ($row['status'] !== 'paused') {
            return self::error(
                'campaign_not_paused',
                'Only a paused campaign can be resumed.',
                Response::HTTP_CONFLICT,
            );
        }

        $now = self::now();
        $scheduled = is_string($row['scheduled_for'])
            ? new DateTimeImmutable(
                $row['scheduled_for'],
                new DateTimeZone('UTC'),
            )
            : $now;

        $status = $scheduled > $now
            ? 'scheduled'
            : 'ready';

        $this->connection->update(
            'campaign',
            [
                'status' => $status,
                'paused_at' => null,
                'last_error' => null,
                'updated_at' => $now->format('Y-m-d H:i:s'),
            ],
            [
                'id' => $campaignId,
                'workspace_id' => $workspaceId,
            ],
        );

        return new JsonResponse(
            $this->campaign(
                $workspaceId,
                $campaignId,
            ),
        );
    }

    #[Route(
        '/{id}/preview',
        name: 'console_campaigns_preview',
        requirements: ['id' => '[1-9][0-9]*'],
        methods: ['POST'],
    )]
    public function preview(
        Request $request,
        string $id,
    ): JsonResponse {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $campaignId = self::positiveId($id);

        if ($campaignId === null) {
            return self::notFound();
        }

        if (!$this->campaignOwned(
            $workspaceId,
            $campaignId,
        )) {
            return self::notFound();
        }

        $payload = self::jsonObject($request);

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        if (array_keys($payload) !== ['variables']) {
            return self::error(
                'invalid_campaign_preview',
                'Expected variables.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $variables = self::variables(
                $payload['variables'],
            );

            $rendered = $this->renderCurrent(
                $workspaceId,
                $campaignId,
                $variables,
            );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_campaign_preview',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        if ($rendered instanceof JsonResponse) {
            return $rendered;
        }

        $response = new JsonResponse([
            'subject' => $rendered['subject'],
            'text' => $rendered['text'],
            'html' => $rendered['html'],
        ]);

        $response->headers->set(
            'Cache-Control',
            'no-store',
        );

        return $response;
    }

    #[Route(
        '/{id}/test',
        name: 'console_campaigns_test',
        requirements: ['id' => '[1-9][0-9]*'],
        methods: ['POST'],
    )]
    public function test(
        Request $request,
        string $id,
    ): JsonResponse {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $campaignId = self::positiveId($id);

        if ($campaignId === null) {
            return self::notFound();
        }

        if (!$this->campaignOwned(
            $workspaceId,
            $campaignId,
        )) {
            return self::notFound();
        }

        $payload = self::jsonObject($request);

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        foreach (array_keys($payload) as $key) {
            if (
                !in_array(
                    $key,
                    ['email', 'name', 'variables'],
                    true,
                )
            ) {
                return self::error(
                    'invalid_campaign_test',
                    'Unexpected test-send field.',
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                );
            }
        }

        if (
            !is_string($payload['email'] ?? null)
            || !is_array($payload['variables'] ?? null)
        ) {
            return self::error(
                'invalid_campaign_test',
                'Test send requires email and variables.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $variables = self::variables(
                $payload['variables'],
            );

            $rendered = $this->renderCurrent(
                $workspaceId,
                $campaignId,
                $variables,
            );

            if ($rendered instanceof JsonResponse) {
                return $rendered;
            }

            $to = [
                'email' => trim(
                    $payload['email'],
                ),
            ];

            if (
                isset($payload['name'])
                && is_string($payload['name'])
                && trim($payload['name']) !== ''
            ) {
                $to['name'] = trim(
                    $payload['name'],
                );
            }

            $outbound = OutboundEmailPayload::fromArray([
                'from' => [
                    'email' => $rendered['sender'],
                ],
                'to' => [$to],
                'subject' => $rendered['subject'],
                'text' => $rendered['text'],
                'html' => $rendered['html'],
            ]);
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_campaign_test',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $submission = $this->submissionService->submit(
            sprintf(
                'campaign-test:%d:%s',
                $campaignId,
                bin2hex(random_bytes(16)),
            ),
            $outbound,
            $workspaceId,
        );

        return new JsonResponse(
            [
                'messageId' => $submission->messageId,
                'status' => $submission->status->value,
                'replayed' => $submission->replayed,
            ],
            Response::HTTP_ACCEPTED,
        );
    }

    /**
     * @param list<string> $from
     */
    private function transition(
        Request $request,
        string $id,
        array $from,
        string $to,
    ): JsonResponse {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $campaignId = self::positiveId($id);

        if ($campaignId === null) {
            return self::notFound();
        }

        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT status
FROM campaign
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
            [
                'id' => $campaignId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($row === false) {
            return self::notFound();
        }

        if (!in_array($row['status'], $from, true)) {
            return self::error(
                'campaign_transition_conflict',
                'Campaign cannot transition from its current state.',
                Response::HTTP_CONFLICT,
            );
        }

        $now = self::now()->format('Y-m-d H:i:s');

        $this->connection->update(
            'campaign',
            [
                'status' => $to,
                'paused_at' => $to === 'paused'
                    ? $now
                    : null,
                'updated_at' => $now,
            ],
            [
                'id' => $campaignId,
                'workspace_id' => $workspaceId,
            ],
        );

        return new JsonResponse(
            $this->campaign(
                $workspaceId,
                $campaignId,
            ),
        );
    }

    /**
     * @param array<string, scalar|null> $variables
     *
     * @return array{
     *     sender:string,
     *     subject:string,
     *     text:string|null,
     *     html:string|null
     * }|JsonResponse
     */
    private function renderCurrent(
        int $workspaceId,
        int $campaignId,
        array $variables,
    ): array|JsonResponse {
        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT
    c.status,
    s.email AS sender_email,
    v.subject,
    v.text_body,
    v.html_body
FROM campaign c
INNER JOIN sender_identity s
    ON s.id = c.sender_identity_id
INNER JOIN sending_domain d
    ON d.id = s.sending_domain_id
INNER JOIN email_template t
    ON t.id = c.template_id
INNER JOIN LATERAL (
    SELECT
        subject,
        text_body,
        html_body
    FROM email_template_version
    WHERE template_id = t.id
    ORDER BY version DESC
    LIMIT 1
) v ON TRUE
WHERE c.id = :campaign_id
  AND c.workspace_id = :workspace_id
  AND d.workspace_id = c.workspace_id
  AND d.status = 'verified'
  AND d.dkim_selector IS NOT NULL
  AND d.dkim_public_key IS NOT NULL
  AND d.dkim_provisioned_at IS NOT NULL
SQL,
            [
                'campaign_id' => $campaignId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($row === false) {
            return self::error(
                'campaign_source_missing',
                'Campaign source resources are not available.',
                Response::HTTP_CONFLICT,
            );
        }

        if ($row['status'] !== 'draft') {
            return self::error(
                'campaign_not_draft',
                'Preview and test send are only available for draft campaigns.',
                Response::HTTP_CONFLICT,
            );
        }

        return [
            'sender' => (string) $row['sender_email'],
            'subject' => $this->renderer->render(
                (string) $row['subject'],
                $variables,
            ),
            'text' => $row['text_body'] === null
                ? null
                : $this->renderer->render(
                    (string) $row['text_body'],
                    $variables,
                ),
            'html' => $row['html_body'] === null
                ? null
                : $this->renderer->render(
                    (string) $row['html_body'],
                    $variables,
                ),
        ];
    }

    /**
     * @return array<string, scalar|null>
     */
    private static function variables(
        mixed $value,
    ): array {
        if (
            !is_array($value)
            || ($value !== [] && array_is_list($value))
        ) {
            throw new InvalidArgumentException(
                'Variables must be a JSON object.',
            );
        }

        $result = [];

        foreach ($value as $key => $item) {
            if (
                !is_string($key)
                || preg_match(
                    '/^[a-z][a-z0-9_]{0,63}$/D',
                    $key,
                ) !== 1
                || (
                    !is_string($item)
                    && !is_int($item)
                    && !is_float($item)
                    && !is_bool($item)
                    && $item !== null
                )
            ) {
                throw new InvalidArgumentException(
                    'Invalid campaign variable.',
                );
            }

            $result[$key] = $item;
        }

        return $result;
    }

    /**
     * @return array<string, mixed>
     */
    private function campaign(
        int $workspaceId,
        int $campaignId,
    ): array {
        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT
    id,
    name,
    status,
    tracking_enabled,
    scheduled_for,
    recipient_count,
    processed_count,
    paused_at,
    completed_at,
    last_error,
    created_at,
    updated_at
FROM campaign
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
            [
                'id' => $campaignId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($row === false) {
            throw new RuntimeException(
                'Campaign cannot be read after mutation.',
            );
        }

        return [
            'id' => (int) $row['id'],
            'name' => (string) $row['name'],
            'status' => (string) $row['status'],
            'trackingEnabled' => (bool) $row['tracking_enabled'],
            'scheduledFor' => self::nullableTimestamp(
                $row['scheduled_for'],
            ),
            'recipientCount' => (int) $row['recipient_count'],
            'processedCount' => (int) $row['processed_count'],
            'pausedAt' => self::nullableTimestamp(
                $row['paused_at'],
            ),
            'completedAt' => self::nullableTimestamp(
                $row['completed_at'],
            ),
            'lastError' => $row['last_error'] === null
                ? null
                : (string) $row['last_error'],
            'createdAt' => self::timestamp(
                $row['created_at'],
            ),
            'updatedAt' => self::timestamp(
                $row['updated_at'],
            ),
        ];
    }

    private function campaignOwned(
        int $workspaceId,
        int $campaignId,
    ): bool {
        return (int) $this->connection->fetchOne(
            <<<'SQL'
SELECT COUNT(*)
FROM campaign
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
            [
                'id' => $campaignId,
                'workspace_id' => $workspaceId,
            ],
        ) === 1;
    }

    private function workspaceId(
        Request $request,
    ): int|JsonResponse {
        $user = $this->authentication->authenticate(
            $request,
        );

        if ($user === null) {
            return self::error(
                'console_unauthorized',
                'Console authentication required.',
                Response::HTTP_UNAUTHORIZED,
            );
        }

        $ids = $this->connection->fetchFirstColumn(
            <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
ORDER BY workspace_id
LIMIT 2
SQL,
            [
                'user_id' => $user['id'],
            ],
        );

        if (count($ids) !== 1) {
            throw new RuntimeException(
                'Expected exactly one console workspace membership.',
            );
        }

        $workspaceId = self::positiveId(
            $ids[0],
        );

        if ($workspaceId === null) {
            throw new RuntimeException(
                'Console workspace identifier is invalid.',
            );
        }

        return $workspaceId;
    }

    /**
     * @return array<string, mixed>|JsonResponse
     */
    private static function jsonObject(
        Request $request,
    ): array|JsonResponse {
        if ($request->getContentTypeFormat() !== 'json') {
            return self::error(
                'unsupported_media_type',
                'Content-Type must be application/json.',
                Response::HTTP_UNSUPPORTED_MEDIA_TYPE,
            );
        }

        $raw = $request->getContent();

        if (strlen($raw) > self::MAX_REQUEST_BYTES) {
            return self::error(
                'payload_too_large',
                'Request body is too large.',
                Response::HTTP_REQUEST_ENTITY_TOO_LARGE,
            );
        }

        try {
            $payload = json_decode(
                $raw,
                true,
                32,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException) {
            return self::error(
                'invalid_json',
                'Request body must contain valid JSON.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        if (!is_array($payload) || array_is_list($payload)) {
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

    private static function nullableTimestamp(
        mixed $value,
    ): ?string {
        return $value === null
            ? null
            : self::timestamp($value);
    }

    private static function timestamp(
        mixed $value,
    ): string {
        if (!is_string($value)) {
            throw new RuntimeException(
                'Campaign timestamp is invalid.',
            );
        }

        return (
            new DateTimeImmutable(
                $value,
                new DateTimeZone('UTC'),
            )
        )->format(DATE_ATOM);
    }

    private static function notFound(): JsonResponse
    {
        return self::error(
            'campaign_not_found',
            'Campaign was not found.',
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
                    'code' => $code,
                    'message' => $message,
                ],
            ],
            $status,
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
