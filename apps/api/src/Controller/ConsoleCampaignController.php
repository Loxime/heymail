<?php
declare(strict_types=1);

namespace App\Controller;

use App\Campaign\CampaignSnapshotCipher;
use App\Console\ConsoleAuthentication;
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
final readonly class ConsoleCampaignController
{
    private const int MAX_REQUEST_BYTES = 16384;
    private const int MAX_RECIPIENTS = 5000;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
        private EmailTemplateRenderer $renderer,
        private CampaignSnapshotCipher $snapshotCipher,
    ) {
    }

    #[Route('', name: 'console_campaigns_list', methods: ['GET'])]
    public function list(Request $request): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);
        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $rows = $this->connection->fetchAllAssociative(
            'SELECT id,name,sender_identity_id,template_id,source_list_id,status,scheduled_for,snapshot_at,template_version,recipient_count,created_at,updated_at
             FROM campaign WHERE workspace_id = :workspace_id ORDER BY id DESC',
            ['workspace_id' => $workspaceId],
        );

        return new JsonResponse(['items' => array_map(self::serialize(...), $rows)]);
    }

    #[Route('', name: 'console_campaigns_create', methods: ['POST'])]
    public function create(Request $request): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);
        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $payload = self::jsonObject($request);
        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        if (array_keys($payload) !== ['name','senderId','templateId','listId']) {
            return self::error(
                'invalid_campaign',
                'Expected name, senderId, templateId and listId.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $name = self::name($payload['name']);
            $senderId = self::requiredId($payload['senderId'], 'senderId');
            $templateId = self::requiredId($payload['templateId'], 'templateId');
            $listId = self::requiredId($payload['listId'], 'listId');
        } catch (InvalidArgumentException $e) {
            return self::error('invalid_campaign', $e->getMessage(), Response::HTTP_UNPROCESSABLE_ENTITY);
        }

        if (!$this->senderAuthorized($workspaceId, $senderId)) {
            return self::error('sender_not_authorized', 'Campaign sender must be an authorized workspace sender.', Response::HTTP_FORBIDDEN);
        }
        if (!$this->owned('email_template', $workspaceId, $templateId)) {
            return self::error('template_not_found', 'Campaign template was not found.', Response::HTTP_NOT_FOUND);
        }
        if (!$this->owned('contact_list', $workspaceId, $listId)) {
            return self::error('list_not_found', 'Campaign contact list was not found.', Response::HTTP_NOT_FOUND);
        }

        $now = self::now()->format('Y-m-d H:i:s');
        $id = self::positiveId($this->connection->fetchOne(
            "INSERT INTO campaign (
                workspace_id,name,sender_identity_id,template_id,source_list_id,status,created_at,updated_at
             ) VALUES (
                :workspace_id,:name,:sender_id,:template_id,:list_id,'draft',:created_at,:updated_at
             ) RETURNING id",
            [
                'workspace_id' => $workspaceId,
                'name' => $name,
                'sender_id' => $senderId,
                'template_id' => $templateId,
                'list_id' => $listId,
                'created_at' => $now,
                'updated_at' => $now,
            ],
        ));

        if ($id === null) {
            throw new RuntimeException('Campaign identifier is invalid.');
        }

        return new JsonResponse($this->campaign($workspaceId, $id), Response::HTTP_CREATED);
    }

    #[Route('/{id}/schedule', name: 'console_campaigns_schedule', requirements: ['id' => '[1-9][0-9]*'], methods: ['POST'])]
    public function schedule(Request $request, string $id): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);
        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $campaignId = self::positiveId($id);
        if ($campaignId === null) {
            return self::notFound();
        }

        $payload = self::jsonObject($request);
        if ($payload instanceof JsonResponse) {
            return $payload;
        }
        if (array_keys($payload) !== ['scheduledFor']) {
            return self::error('invalid_campaign_schedule', 'Expected scheduledFor.', Response::HTTP_UNPROCESSABLE_ENTITY);
        }

        try {
            $scheduledFor = self::scheduledFor($payload['scheduledFor']);
        } catch (InvalidArgumentException $e) {
            return self::error('invalid_campaign_schedule', $e->getMessage(), Response::HTTP_UNPROCESSABLE_ENTITY);
        }

        $this->connection->beginTransaction();

        try {
            $campaign = $this->connection->fetchAssociative(
                'SELECT sender_identity_id,template_id,source_list_id,status
                 FROM campaign
                 WHERE id = :id AND workspace_id = :workspace_id FOR UPDATE',
                ['id' => $campaignId, 'workspace_id' => $workspaceId],
            );

            if ($campaign === false) {
                $this->connection->rollBack();
                return self::notFound();
            }
            if ($campaign['status'] !== 'draft') {
                $this->connection->rollBack();
                return self::error('campaign_not_draft', 'Only a draft campaign can be scheduled.', Response::HTTP_CONFLICT);
            }

            $senderId = self::positiveId($campaign['sender_identity_id']);
            $templateId = self::positiveId($campaign['template_id']);
            $listId = self::positiveId($campaign['source_list_id']);

            if ($senderId === null || $templateId === null || $listId === null) {
                $this->connection->rollBack();
                return self::error('campaign_source_missing', 'Campaign source resources are no longer available.', Response::HTTP_CONFLICT);
            }

            $sender = $this->connection->fetchAssociative(
                "SELECT s.email
                 FROM sender_identity s
                 INNER JOIN sending_domain d ON d.id = s.sending_domain_id
                 WHERE s.id = :sender_id
                   AND d.workspace_id = :workspace_id
                   AND d.status = 'verified'
                   AND d.dkim_selector IS NOT NULL
                   AND d.dkim_public_key IS NOT NULL
                   AND d.dkim_provisioned_at IS NOT NULL",
                ['sender_id' => $senderId, 'workspace_id' => $workspaceId],
            );

            $template = $this->connection->fetchAssociative(
                "SELECT v.version,v.subject,v.text_body,v.html_body
                 FROM email_template t
                 INNER JOIN LATERAL (
                    SELECT version,subject,text_body,html_body
                    FROM email_template_version
                    WHERE template_id = t.id
                    ORDER BY version DESC
                    LIMIT 1
                 ) v ON TRUE
                 WHERE t.id = :template_id AND t.workspace_id = :workspace_id",
                ['template_id' => $templateId, 'workspace_id' => $workspaceId],
            );

            if ($sender === false || $template === false || !$this->owned('contact_list', $workspaceId, $listId)) {
                $this->connection->rollBack();
                return self::error('campaign_source_missing', 'Campaign source resources are no longer usable.', Response::HTTP_CONFLICT);
            }

            $contacts = $this->connection->fetchAllAssociative(
                'SELECT c.id,c.email,c.name,c.custom_fields
                 FROM contact_list_member m
                 INNER JOIN contact c ON c.workspace_id = m.workspace_id AND c.id = m.contact_id
                 WHERE m.workspace_id = :workspace_id AND m.list_id = :list_id
                 ORDER BY c.id
                 LIMIT ' . (self::MAX_RECIPIENTS + 1),
                ['workspace_id' => $workspaceId, 'list_id' => $listId],
            );

            if ($contacts === []) {
                $this->connection->rollBack();
                return self::error('campaign_audience_empty', 'Campaign contact list is empty.', Response::HTTP_CONFLICT);
            }
            if (count($contacts) > self::MAX_RECIPIENTS) {
                $this->connection->rollBack();
                return self::error('campaign_audience_too_large', 'Campaign audience exceeds 5000 recipients.', Response::HTTP_UNPROCESSABLE_ENTITY);
            }

            $variables = [];
            foreach ([
                (string) $template['subject'],
                is_string($template['text_body']) ? $template['text_body'] : '',
                is_string($template['html_body']) ? $template['html_body'] : '',
            ] as $part) {
                $variables = [...$variables, ...$this->renderer->variables($part)];
            }
            $variables = array_values(array_unique($variables));
            sort($variables, SORT_STRING);

            $recipients = [];
            foreach ($contacts as $contact) {
                $custom = self::decodeObject($contact['custom_fields'] ?? '{}');
                $name = $contact['name'] === null ? null : (string) $contact['name'];
                $values = [
                    'email' => (string) $contact['email'],
                    'name' => $name ?? '',
                    'first_name' => self::firstName($name),
                    ...$custom,
                ];
                $selected = [];

                foreach ($variables as $variable) {
                    if (!array_key_exists($variable, $values)) {
                        $this->connection->rollBack();
                        return self::error(
                            'campaign_variable_missing',
                            sprintf('Contact %d is missing template variable %s.', (int) $contact['id'], $variable),
                            Response::HTTP_UNPROCESSABLE_ENTITY,
                        );
                    }
                    $selected[$variable] = $values[$variable];
                }

                $recipients[] = [
                    'email' => (string) $contact['email'],
                    'name' => $name,
                    'variables' => $selected,
                ];
            }

            $encrypted = $this->snapshotCipher->encrypt(
                $workspaceId,
                $campaignId,
                [
                    'sender' => ['email' => (string) $sender['email']],
                    'template' => [
                        'version' => (int) $template['version'],
                        'subject' => (string) $template['subject'],
                        'text' => $template['text_body'] === null ? null : (string) $template['text_body'],
                        'html' => $template['html_body'] === null ? null : (string) $template['html_body'],
                    ],
                    'recipients' => $recipients,
                ],
            );

            $now = self::now();
            $effective = $scheduledFor ?? $now;
            $status = $effective > $now ? 'scheduled' : 'ready';

            $this->connection->update('campaign', [
                'status' => $status,
                'scheduled_for' => $effective->format('Y-m-d H:i:s'),
                'snapshot_at' => $now->format('Y-m-d H:i:s'),
                'template_version' => (int) $template['version'],
                'recipient_count' => count($recipients),
                'snapshot_ciphertext' => $encrypted['ciphertext'],
                'snapshot_nonce' => $encrypted['nonce'],
                'snapshot_wrapped_dek' => $encrypted['wrappedDek'],
                'snapshot_wrap_nonce' => $encrypted['wrapNonce'],
                'snapshot_algorithm' => $encrypted['algorithm'],
                'snapshot_key_version' => $encrypted['keyVersion'],
                'updated_at' => $now->format('Y-m-d H:i:s'),
            ], [
                'id' => $campaignId,
                'workspace_id' => $workspaceId,
            ]);

            $this->connection->commit();
        } catch (\Throwable $e) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }
            throw $e;
        }

        return new JsonResponse($this->campaign($workspaceId, $campaignId));
    }

    #[Route('/{id}/cancel', name: 'console_campaigns_cancel', requirements: ['id' => '[1-9][0-9]*'], methods: ['POST'])]
    public function cancel(Request $request, string $id): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);
        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $campaignId = self::positiveId($id);
        if ($campaignId === null) {
            return self::notFound();
        }

        $changed = $this->connection->executeStatement(
            "UPDATE campaign
             SET status = 'cancelled', updated_at = :updated_at
             WHERE id = :id AND workspace_id = :workspace_id
               AND status IN ('draft','scheduled','ready')",
            [
                'updated_at' => self::now()->format('Y-m-d H:i:s'),
                'id' => $campaignId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($changed !== 1) {
            if (!$this->owned('campaign', $workspaceId, $campaignId)) {
                return self::notFound();
            }
            return self::error('campaign_not_cancellable', 'Campaign cannot be cancelled from its current state.', Response::HTTP_CONFLICT);
        }

        return new JsonResponse($this->campaign($workspaceId, $campaignId));
    }

    private function senderAuthorized(int $workspaceId, int $senderId): bool
    {
        return (int) $this->connection->fetchOne(
            "SELECT COUNT(*)
             FROM sender_identity s
             INNER JOIN sending_domain d ON d.id = s.sending_domain_id
             WHERE s.id = :id AND d.workspace_id = :workspace_id
               AND d.status = 'verified'
               AND d.dkim_selector IS NOT NULL
               AND d.dkim_public_key IS NOT NULL
               AND d.dkim_provisioned_at IS NOT NULL",
            ['id' => $senderId, 'workspace_id' => $workspaceId],
        ) === 1;
    }

    private function owned(string $table, int $workspaceId, int $id): bool
    {
        if (!in_array($table, ['campaign','email_template','contact_list'], true)) {
            throw new RuntimeException('Invalid campaign ownership table.');
        }

        return (int) $this->connection->fetchOne(
            sprintf('SELECT COUNT(*) FROM %s WHERE id = :id AND workspace_id = :workspace_id', $table),
            ['id' => $id, 'workspace_id' => $workspaceId],
        ) === 1;
    }

    /** @return array<string,mixed> */
    private function campaign(int $workspaceId, int $campaignId): array
    {
        $row = $this->connection->fetchAssociative(
            'SELECT id,name,sender_identity_id,template_id,source_list_id,status,scheduled_for,snapshot_at,template_version,recipient_count,created_at,updated_at
             FROM campaign WHERE id = :id AND workspace_id = :workspace_id',
            ['id' => $campaignId, 'workspace_id' => $workspaceId],
        );

        if ($row === false) {
            throw new RuntimeException('Campaign cannot be read after mutation.');
        }

        return self::serialize($row);
    }

    /** @param array<string,mixed> $row @return array<string,mixed> */
    private static function serialize(array $row): array
    {
        return [
            'id' => (int) $row['id'],
            'name' => (string) $row['name'],
            'senderId' => self::positiveId($row['sender_identity_id']),
            'templateId' => self::positiveId($row['template_id']),
            'listId' => self::positiveId($row['source_list_id']),
            'status' => (string) $row['status'],
            'scheduledFor' => $row['scheduled_for'] === null ? null : self::timestamp($row['scheduled_for']),
            'snapshotAt' => $row['snapshot_at'] === null ? null : self::timestamp($row['snapshot_at']),
            'templateVersion' => $row['template_version'] === null ? null : (int) $row['template_version'],
            'recipientCount' => (int) $row['recipient_count'],
            'createdAt' => self::timestamp($row['created_at']),
            'updatedAt' => self::timestamp($row['updated_at']),
        ];
    }

    private function workspaceId(Request $request): int|JsonResponse
    {
        $user = $this->authentication->authenticate($request);
        if ($user === null) {
            return self::error('console_unauthorized', 'Console authentication required.', Response::HTTP_UNAUTHORIZED);
        }

        $ids = $this->connection->fetchFirstColumn(
            'SELECT workspace_id FROM workspace_member WHERE user_id = :user_id ORDER BY workspace_id LIMIT 2',
            ['user_id' => $user['id']],
        );

        if (count($ids) !== 1) {
            throw new RuntimeException('Expected exactly one console workspace membership.');
        }

        $id = self::positiveId($ids[0]);
        if ($id === null) {
            throw new RuntimeException('Console workspace identifier is invalid.');
        }

        return $id;
    }

    /** @return array<string,mixed>|JsonResponse */
    private static function jsonObject(Request $request): array|JsonResponse
    {
        if ($request->getContentTypeFormat() !== 'json') {
            return self::error('unsupported_media_type', 'Content-Type must be application/json.', Response::HTTP_UNSUPPORTED_MEDIA_TYPE);
        }

        $raw = $request->getContent();
        if (strlen($raw) > self::MAX_REQUEST_BYTES) {
            return self::error('payload_too_large', 'Request body is too large.', Response::HTTP_REQUEST_ENTITY_TOO_LARGE);
        }

        try {
            $payload = json_decode($raw, true, 32, JSON_THROW_ON_ERROR);
        } catch (JsonException) {
            return self::error('invalid_json', 'Request body must contain valid JSON.', Response::HTTP_BAD_REQUEST);
        }

        if (!is_array($payload) || array_is_list($payload)) {
            return self::error('invalid_payload', 'Request body must contain a JSON object.', Response::HTTP_UNPROCESSABLE_ENTITY);
        }

        return $payload;
    }

    private static function scheduledFor(mixed $value): ?DateTimeImmutable
    {
        if ($value === null) {
            return null;
        }

        if (
            !is_string($value)
            || strlen($value) > 64
            || preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/D', $value) !== 1
        ) {
            throw new InvalidArgumentException('scheduledFor must be null or an RFC 3339 timestamp.');
        }

        try {
            return (new DateTimeImmutable($value))->setTimezone(new DateTimeZone('UTC'));
        } catch (\Exception $e) {
            throw new InvalidArgumentException('scheduledFor must be null or an RFC 3339 timestamp.', 0, $e);
        }
    }

    private static function name(mixed $value): string
    {
        if (!is_string($value)) {
            throw new InvalidArgumentException('Campaign name is required.');
        }

        $value = trim($value);
        if ($value === '' || strlen($value) > 160 || preg_match('/[\x00-\x1F\x7F]/', $value) === 1) {
            throw new InvalidArgumentException('Campaign name is invalid.');
        }

        return $value;
    }

    private static function requiredId(mixed $value, string $label): int
    {
        $id = self::positiveId($value);
        if ($id === null) {
            throw new InvalidArgumentException($label . ' must be a positive identifier.');
        }
        return $id;
    }

    private static function positiveId(mixed $value): ?int
    {
        $id = filter_var($value, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]);
        return is_int($id) ? $id : null;
    }

    /** @return array<string,scalar|null> */
    private static function decodeObject(mixed $value): array
    {
        $decoded = is_array($value)
            ? $value
            : (is_string($value) ? json_decode($value, true, 32, JSON_THROW_ON_ERROR) : null);

        if (!is_array($decoded) || ($decoded !== [] && array_is_list($decoded))) {
            throw new RuntimeException('Invalid contact custom fields.');
        }
        return $decoded;
    }

    private static function firstName(?string $name): string
    {
        if ($name === null || trim($name) === '') {
            return '';
        }

        return preg_split('/\s+/u', trim($name), 2)[0] ?? '';
    }

    private static function timestamp(mixed $value): string
    {
        if (!is_string($value)) {
            throw new RuntimeException('Campaign timestamp is invalid.');
        }

        return (new DateTimeImmutable($value, new DateTimeZone('UTC')))->format(DATE_ATOM);
    }

    private static function notFound(): JsonResponse
    {
        return self::error('campaign_not_found', 'Campaign was not found.', Response::HTTP_NOT_FOUND);
    }

    private static function error(string $code, string $message, int $status): JsonResponse
    {
        return new JsonResponse(['error' => ['code' => $code, 'message' => $message]], $status);
    }

    private static function now(): DateTimeImmutable
    {
        return new DateTimeImmutable('now', new DateTimeZone('UTC'));
    }
}
