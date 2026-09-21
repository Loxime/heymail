<?php

declare(strict_types=1);

namespace App\Controller;

use App\Console\ConsoleAuthentication;
use App\Suppression\EmailSuppressionService;
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

#[Route('/console/suppressions')]
final readonly class ConsoleSuppressionController
{
    private const int MAX_REQUEST_BYTES = 16384;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
        private EmailSuppressionService $suppressions,
    ) {
    }

    #[Route(
        '',
        name: 'console_suppressions_list',
        methods: ['GET'],
    )]
    public function list(
        Request $request,
    ): JsonResponse {
        $workspaceId = $this->workspaceId(
            $request,
        );

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $rows = $this->connection->fetchAllAssociative(
            <<<'SQL'
SELECT
    id,
    email,
    scope,
    reason,
    contact_list_id,
    source_outbound_message_id,
    created_at,
    updated_at
FROM email_suppression
WHERE workspace_id = :workspace_id
ORDER BY id DESC
LIMIT 500
SQL,
            [
                'workspace_id'
                    => $workspaceId,
            ],
        );

        return new JsonResponse([
            'items' => array_map(
                self::serialize(...),
                $rows,
            ),
        ]);
    }

    #[Route(
        '',
        name: 'console_suppressions_create',
        methods: ['POST'],
    )]
    public function create(
        Request $request,
    ): JsonResponse {
        $workspaceId = $this->workspaceId(
            $request,
        );

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $payload = self::jsonObject(
            $request,
        );

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        $keys = array_keys(
            $payload,
        );

        sort(
            $keys,
        );

        if (
            $keys !== ['email']
            && $keys !== [
                'email',
                'listId',
            ]
        ) {
            return self::error(
                'invalid_suppression',
                'Expected email and optional listId.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        if (!is_string(
            $payload['email'] ?? null,
        )) {
            return self::error(
                'invalid_suppression',
                'Suppression email is required.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $listId = null;

        if (
            array_key_exists(
                'listId',
                $payload,
            )
            && $payload['listId'] !== null
        ) {
            $listId = self::positiveId(
                $payload['listId'],
            );

            if ($listId === null) {
                return self::error(
                    'invalid_suppression',
                    'listId must be null or a positive identifier.',
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                );
            }

            if (
                (int) $this->connection->fetchOne(
                    <<<'SQL'
SELECT COUNT(*)
FROM contact_list
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
                    [
                        'id' => $listId,
                        'workspace_id'
                            => $workspaceId,
                    ],
                ) !== 1
            ) {
                return self::error(
                    'list_not_found',
                    'Contact list was not found.',
                    Response::HTTP_NOT_FOUND,
                );
            }
        }

        try {
            $suppressionId = $listId === null
                ? $this->suppressions
                    ->suppressGlobal(
                        workspaceId:
                            $workspaceId,
                        email:
                            $payload['email'],
                        reason: 'manual',
                    )
                : $this->suppressions
                    ->suppressList(
                        workspaceId:
                            $workspaceId,
                        contactListId:
                            $listId,
                        email:
                            $payload['email'],
                        reason: 'manual',
                    );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_suppression',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        return new JsonResponse(
            $this->suppression(
                $workspaceId,
                $suppressionId,
            ),
            Response::HTTP_CREATED,
        );
    }

    #[Route(
        '/{id}',
        name: 'console_suppressions_delete',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['DELETE'],
    )]
    public function delete(
        Request $request,
        string $id,
    ): JsonResponse {
        $workspaceId = $this->workspaceId(
            $request,
        );

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $suppressionId = self::positiveId(
            $id,
        );

        if ($suppressionId === null) {
            return self::notFound();
        }

        $changed = $this->connection->executeStatement(
            <<<'SQL'
DELETE FROM email_suppression
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
            [
                'id' => $suppressionId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($changed !== 1) {
            return self::notFound();
        }

        return new JsonResponse(
            null,
            Response::HTTP_NO_CONTENT,
        );
    }

    /**
     * @return array<string, mixed>
     */
    private function suppression(
        int $workspaceId,
        int $suppressionId,
    ): array {
        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT
    id,
    email,
    scope,
    reason,
    contact_list_id,
    source_outbound_message_id,
    created_at,
    updated_at
FROM email_suppression
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
            [
                'id' => $suppressionId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($row === false) {
            throw new RuntimeException(
                'Suppression cannot be read after mutation.',
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
        return [
            'id' => (int) $row['id'],
            'email' => (string) $row['email'],
            'scope' => (string) $row['scope'],
            'reason' => (string) $row['reason'],
            'listId' => $row['contact_list_id'] === null
                ? null
                : (int) $row['contact_list_id'],
            'sourceMessageId'
                => $row['source_outbound_message_id'] === null
                    ? null
                    : (int) $row['source_outbound_message_id'],
            'createdAt' => self::timestamp(
                $row['created_at'],
            ),
            'updatedAt' => self::timestamp(
                $row['updated_at'],
            ),
        ];
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

        $raw = $request->getContent();

        if (
            strlen($raw)
            > self::MAX_REQUEST_BYTES
        ) {
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

    private static function timestamp(
        mixed $value,
    ): string {
        if (!is_string($value)) {
            throw new RuntimeException(
                'Suppression timestamp is invalid.',
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
            'suppression_not_found',
            'Suppression was not found.',
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
}
