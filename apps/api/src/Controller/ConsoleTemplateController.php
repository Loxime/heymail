<?php

declare(strict_types=1);

namespace App\Controller;

use App\Console\ConsoleAuthentication;
use App\Template\EmailTemplateRenderer;
use App\Template\VisualEmailDocumentRenderer;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception\UniqueConstraintViolationException;
use Doctrine\DBAL\Types\Types;
use InvalidArgumentException;
use JsonException;
use RuntimeException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/console/templates')]
final readonly class ConsoleTemplateController
{
    private const int MAX_REQUEST_BYTES = 3500000;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
        private EmailTemplateRenderer $renderer,
        private VisualEmailDocumentRenderer $visualRenderer,
    ) {
    }

    #[Route('', name: 'console_templates_list', methods: ['GET'])]
    public function list(Request $request): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $rows = $this->connection->fetchAllAssociative(
            <<<'SQL'
SELECT
    t.id,
    t.name,
    t.created_at,
    t.updated_at,
    v.version,
    v.subject,
    v.text_body,
    v.html_body,
    v.visual_document,
    v.created_at AS version_created_at
FROM email_template t
INNER JOIN LATERAL (
    SELECT
        version,
        subject,
        text_body,
        html_body,
        visual_document,
        created_at
    FROM email_template_version
    WHERE template_id = t.id
    ORDER BY version DESC
    LIMIT 1
) v ON TRUE
WHERE t.workspace_id = :workspace_id
ORDER BY t.id DESC
SQL,
            ['workspace_id' => $workspaceId],
        );

        return new JsonResponse([
            'items' => array_map(
                fn (array $row): array => $this->serialize($row),
                $rows,
            ),
        ]);
    }

    #[Route('', name: 'console_templates_create', methods: ['POST'])]
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

        try {
            $name = self::name($payload['name'] ?? null);
            $content = $this->content($payload);
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_template',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $this->connection->beginTransaction();

        try {
            $now = self::now()->format('Y-m-d H:i:s');

            $templateId = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
INSERT INTO email_template (
    workspace_id,
    name,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    :created_at,
    :updated_at
)
RETURNING id
SQL,
                    [
                        'workspace_id' => $workspaceId,
                        'name' => $name,
                        'created_at' => $now,
                        'updated_at' => $now,
                    ],
                ),
            );

            if ($templateId === null) {
                throw new RuntimeException('Template identifier is invalid.');
            }

            $this->connection->insert(
                'email_template_version',
                [
                    'template_id' => $templateId,
                    'version' => 1,
                    'subject' => $content['subject'],
                    'text_body' => $content['text'],
                    'html_body' => $content['html'],
                    'visual_document'
                        => $content['visual'],
                    'created_at' => $now,
                ],
                [
                    'visual_document'
                        => Types::JSON,
                ],
            );

            $this->connection->commit();
        } catch (UniqueConstraintViolationException) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            return self::error(
                'template_conflict',
                'A template with this name already exists in the workspace.',
                Response::HTTP_CONFLICT,
            );
        } catch (\Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }

        return new JsonResponse(
            $this->templateById($workspaceId, $templateId),
            Response::HTTP_CREATED,
        );
    }

    #[Route('/{id}/versions', name: 'console_templates_update', requirements: ['id' => '[1-9][0-9]*'], methods: ['POST'])]
    public function createVersion(Request $request, string $id): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $templateId = self::positiveId($id);

        if ($templateId === null) {
            return self::notFound();
        }

        $payload = self::jsonObject($request);

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        try {
            $content = $this->content($payload);
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_template',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $this->connection->beginTransaction();

        try {
            $owned = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
SELECT id
FROM email_template
WHERE id = :id
  AND workspace_id = :workspace_id
FOR UPDATE
SQL,
                    [
                        'id' => $templateId,
                        'workspace_id' => $workspaceId,
                    ],
                ),
            );

            if ($owned === null) {
                $this->connection->rollBack();
                return self::notFound();
            }

            $latest = (int) $this->connection->fetchOne(
                <<<'SQL'
SELECT COALESCE(MAX(version), 0)
FROM email_template_version
WHERE template_id = :template_id
SQL,
                ['template_id' => $templateId],
            );

            $now = self::now()->format('Y-m-d H:i:s');

            $this->connection->insert(
                'email_template_version',
                [
                    'template_id' => $templateId,
                    'version' => $latest + 1,
                    'subject' => $content['subject'],
                    'text_body' => $content['text'],
                    'html_body' => $content['html'],
                    'visual_document'
                        => $content['visual'],
                    'created_at' => $now,
                ],
                [
                    'visual_document'
                        => Types::JSON,
                ],
            );

            $this->connection->update(
                'email_template',
                ['updated_at' => $now],
                [
                    'id' => $templateId,
                    'workspace_id' => $workspaceId,
                ],
            );

            $this->connection->commit();
        } catch (\Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }

        return new JsonResponse(
            $this->templateById($workspaceId, $templateId),
        );
    }

    #[Route('/{id}/duplicate', name: 'console_templates_duplicate', requirements: ['id' => '[1-9][0-9]*'], methods: ['POST'])]
    public function duplicate(Request $request, string $id): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $templateId = self::positiveId($id);

        if ($templateId === null) {
            return self::notFound();
        }

        $source = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT
    t.name,
    v.subject,
    v.text_body,
    v.html_body,
    v.visual_document
FROM email_template t
INNER JOIN LATERAL (
    SELECT
        subject,
        text_body,
        html_body,
        visual_document
    FROM email_template_version
    WHERE template_id = t.id
    ORDER BY version DESC
    LIMIT 1
) v ON TRUE
WHERE t.id = :id
  AND t.workspace_id = :workspace_id
SQL,
            [
                'id' => $templateId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($source === false) {
            return self::notFound();
        }

        $baseName = rtrim(
            substr((string) $source['name'], 0, 145),
        ) . ' copy';

        for ($attempt = 1; $attempt <= 99; ++$attempt) {
            $name = $baseName
                . ($attempt === 1 ? '' : ' ' . $attempt);

            $this->connection->beginTransaction();

            try {
                $now = self::now()->format('Y-m-d H:i:s');

                $newId = self::positiveId(
                    $this->connection->fetchOne(
                        <<<'SQL'
INSERT INTO email_template (
    workspace_id,
    name,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    :created_at,
    :updated_at
)
RETURNING id
SQL,
                        [
                            'workspace_id' => $workspaceId,
                            'name' => $name,
                            'created_at' => $now,
                            'updated_at' => $now,
                        ],
                    ),
                );

                if ($newId === null) {
                    throw new RuntimeException(
                        'Duplicated template identifier is invalid.',
                    );
                }

                $this->connection->insert(
                    'email_template_version',
                    [
                        'template_id' => $newId,
                        'version' => 1,
                        'subject' => (string) $source['subject'],
                        'text_body' => $source['text_body'],
                        'html_body' => $source['html_body'],
                        'visual_document'
                            => $this->visualDocument(
                                $source['visual_document'],
                            ),
                        'created_at' => $now,
                    ],
                    [
                        'visual_document'
                            => Types::JSON,
                    ],
                );

                $this->connection->commit();

                return new JsonResponse(
                    $this->templateById($workspaceId, $newId),
                    Response::HTTP_CREATED,
                );
            } catch (UniqueConstraintViolationException) {
                if ($this->connection->isTransactionActive()) {
                    $this->connection->rollBack();
                }
            } catch (\Throwable $exception) {
                if ($this->connection->isTransactionActive()) {
                    $this->connection->rollBack();
                }

                throw $exception;
            }
        }

        return self::error(
            'template_conflict',
            'Unable to allocate a unique duplicate template name.',
            Response::HTTP_CONFLICT,
        );
    }

    #[Route('/{id}/render', name: 'console_templates_render', requirements: ['id' => '[1-9][0-9]*'], methods: ['POST'])]
    public function render(Request $request, string $id): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $templateId = self::positiveId($id);

        if ($templateId === null) {
            return self::notFound();
        }

        $payload = self::jsonObject($request);

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        if (array_keys($payload) !== ['variables']) {
            return self::error(
                'invalid_payload',
                'Expected variables.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $variables = $payload['variables'];

        if (
            !is_array($variables)
            || ($variables !== [] && array_is_list($variables))
        ) {
            return self::error(
                'invalid_payload',
                'Template variables must be a JSON object.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT
    t.name,
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
WHERE t.id = :id
  AND t.workspace_id = :workspace_id
SQL,
            [
                'id' => $templateId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($row === false) {
            return self::notFound();
        }

        try {
            $subject = $this->renderer->render(
                (string) $row['subject'],
                $variables,
            );

            $text = $row['text_body'] === null
                ? null
                : $this->renderer->render(
                    (string) $row['text_body'],
                    $variables,
                );

            $html = $row['html_body'] === null
                ? null
                : $this->renderer->render(
                    (string) $row['html_body'],
                    $variables,
                );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_template_variables',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $response = new JsonResponse([
            'templateId' => $templateId,
            'name' => (string) $row['name'],
            'version' => (int) $row['version'],
            'subject' => $subject,
            'text' => $text,
            'html' => $html,
        ]);

        $response->headers->set(
            'Cache-Control',
            'no-store',
        );

        return $response;
    }

    #[Route('/{id}/history', name: 'console_templates_history', requirements: ['id' => '[1-9][0-9]*'], methods: ['GET'])]
    public function history(Request $request, string $id): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $templateId = self::positiveId($id);

        if (
            $templateId === null
            || (int) $this->connection->fetchOne(
                'SELECT COUNT(*) FROM email_template WHERE id = :id AND workspace_id = :workspace_id',
                [
                    'id' => $templateId,
                    'workspace_id' => $workspaceId,
                ],
            ) !== 1
        ) {
            return self::notFound();
        }

        $rows = $this->connection->fetchAllAssociative(
            <<<'SQL'
SELECT
    id,
    version,
    subject,
    text_body,
    html_body,
    visual_document,
    created_at
FROM email_template_version
WHERE template_id = :template_id
ORDER BY version DESC
SQL,
            ['template_id' => $templateId],
        );

        return new JsonResponse([
            'items' => array_map(
                fn (array $row): array => [
                    'id' => (int) $row['id'],
                    'version' => (int) $row['version'],
                    'subject' => (string) $row['subject'],
                    'text' => $row['text_body'] === null ? null : (string) $row['text_body'],
                    'html' => $row['html_body'] === null ? null : (string) $row['html_body'],
                    'visual'
                        => $this->visualDocument(
                            $row['visual_document'],
                        ),
                    'variables' => $this->variables(
                        (string) $row['subject'],
                        $row['text_body'],
                        $row['html_body'],
                    ),
                    'createdAt' => self::timestamp($row['created_at']),
                ],
                $rows,
            ),
        ]);
    }

    private function workspaceId(Request $request): int|JsonResponse
    {
        $user = $this->authentication->authenticate($request);

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
            ['user_id' => $user['id']],
        );

        if (count($ids) !== 1) {
            throw new RuntimeException(
                'Expected exactly one console workspace membership.',
            );
        }

        $workspaceId = self::positiveId($ids[0]);

        if ($workspaceId === null) {
            throw new RuntimeException(
                'Console workspace identifier is invalid.',
            );
        }

        return $workspaceId;
    }

    private static function name(mixed $value): string
    {
        if (!is_string($value)) {
            throw new InvalidArgumentException('Template name is required.');
        }

        $value = trim($value);

        if (
            $value === ''
            || strlen($value) > 160
            || preg_match('/[\x00-\x1F\x7F]/', $value) === 1
        ) {
            throw new InvalidArgumentException('Template name is invalid.');
        }

        return $value;
    }

    /**
     * @return array{
     *     subject:string,
     *     text:string|null,
     *     html:string|null,
     *     visual:array<string,mixed>|null
     * }
     */
    private function content(
        array $payload,
    ): array {
        foreach (
            array_keys($payload)
            as $key
        ) {
            if (
                !in_array(
                    $key,
                    [
                        'name',
                        'subject',
                        'text',
                        'html',
                        'visual',
                    ],
                    true,
                )
            ) {
                throw new InvalidArgumentException(
                    'Unexpected template field.',
                );
            }
        }

        $subject =
            $payload['subject']
            ?? null;

        $text =
            $payload['text']
            ?? null;

        $html =
            $payload['html']
            ?? null;

        $visualValue =
            $payload['visual']
            ?? null;

        if (
            !is_string($subject)
            || trim($subject) === ''
            || strlen($subject) > 255
            || preg_match(
                '/[\x00-\x1F\x7F]/',
                $subject,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Template subject is invalid.',
            );
        }

        if ($visualValue !== null) {
            if (
                $html !== null
                && $html !== ''
            ) {
                throw new InvalidArgumentException(
                    'Visual template HTML is generated by the server.',
                );
            }

            $visual =
                $this
                    ->visualRenderer
                    ->normalize(
                        $visualValue,
                    );

            $html =
                $this
                    ->visualRenderer
                    ->render(
                        $visual,
                    );
        } else {
            $visual = null;
        }

        foreach (
            [
                'text'
                    => [
                        $text,
                        1048576,
                    ],
                'html'
                    => [
                        $html,
                        2097152,
                    ],
            ]
            as $label => [
                $value,
                $max,
            ]
        ) {
            if (
                $value !== null
                && (
                    !is_string($value)
                    || strlen($value) > $max
                    || str_contains(
                        $value,
                        "\0",
                    )
                )
            ) {
                throw new InvalidArgumentException(
                    sprintf(
                        'Template %s body is invalid.',
                        $label,
                    ),
                );
            }
        }

        if (
            ($text === null || $text === '')
            && ($html === null || $html === '')
        ) {
            throw new InvalidArgumentException(
                'Template requires text or HTML content.',
            );
        }

        return [
            'subject' => $subject,
            'text' => $text,
            'html' => $html,
            'visual' => $visual,
        ];
    }

    /**
     * @return array<string,mixed>
     */
    private function templateById(int $workspaceId, int $templateId): array
    {
        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT
    t.id,
    t.name,
    t.created_at,
    t.updated_at,
    v.version,
    v.subject,
    v.text_body,
    v.html_body,
    v.visual_document,
    v.created_at AS version_created_at
FROM email_template t
INNER JOIN LATERAL (
    SELECT
        version,
        subject,
        text_body,
        html_body,
        visual_document,
        created_at
    FROM email_template_version
    WHERE template_id = t.id
    ORDER BY version DESC
    LIMIT 1
) v ON TRUE
WHERE t.id = :id
  AND t.workspace_id = :workspace_id
SQL,
            [
                'id' => $templateId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($row === false) {
            throw new RuntimeException(
                'Template cannot be read after mutation.',
            );
        }

        return $this->serialize($row);
    }

    /**
     * @return array<string,mixed>
     */
    private function serialize(array $row): array
    {
        return [
            'id' => (int) $row['id'],
            'name' => (string) $row['name'],
            'version' => (int) $row['version'],
            'subject' => (string) $row['subject'],
            'text' => $row['text_body'] === null ? null : (string) $row['text_body'],
            'html' => $row['html_body'] === null ? null : (string) $row['html_body'],
            'visual'
                => $this->visualDocument(
                    $row['visual_document'],
                ),
            'variables' => $this->variables(
                (string) $row['subject'],
                $row['text_body'],
                $row['html_body'],
            ),
            'createdAt' => self::timestamp($row['created_at']),
            'updatedAt' => self::timestamp($row['updated_at']),
            'versionCreatedAt' => self::timestamp($row['version_created_at']),
        ];
    }

    /**
     * @return array<string,mixed>|null
     */
    private function visualDocument(
        mixed $value,
    ): ?array {
        if ($value === null) {
            return null;
        }

        if (is_string($value)) {
            try {
                $value =
                    json_decode(
                        $value,
                        true,
                        64,
                        JSON_THROW_ON_ERROR,
                    );
            } catch (JsonException $exception) {
                throw new RuntimeException(
                    'Stored visual email document is invalid.',
                    0,
                    $exception,
                );
            }
        }

        if (
            !is_array($value)
            || array_is_list($value)
        ) {
            throw new RuntimeException(
                'Stored visual email document is invalid.',
            );
        }

        return $this
            ->visualRenderer
            ->normalize(
                $value,
            );
    }

    /**
     * @return list<string>
     */
    private function variables(string $subject, mixed $text, mixed $html): array
    {
        $variables = [];

        foreach ([
            $subject,
            is_string($text) ? $text : '',
            is_string($html) ? $html : '',
        ] as $value) {
            $variables = [
                ...$variables,
                ...$this->renderer->variables($value),
            ];
        }

        $variables = array_values(array_unique($variables));
        sort($variables, SORT_STRING);

        return $variables;
    }

    /**
     * @return array<string,mixed>|JsonResponse
     */
    private static function jsonObject(Request $request): array|JsonResponse
    {
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

    private static function positiveId(mixed $value): ?int
    {
        $id = filter_var(
            $value,
            FILTER_VALIDATE_INT,
            ['options' => ['min_range' => 1]],
        );

        return is_int($id) ? $id : null;
    }

    private static function timestamp(mixed $value): string
    {
        if (!is_string($value)) {
            throw new RuntimeException('Template timestamp is invalid.');
        }

        return (new DateTimeImmutable(
            $value,
            new DateTimeZone('UTC'),
        ))->format(DATE_ATOM);
    }

    private static function notFound(): JsonResponse
    {
        return self::error(
            'template_not_found',
            'Template was not found.',
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
