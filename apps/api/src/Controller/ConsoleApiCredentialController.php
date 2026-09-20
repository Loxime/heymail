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

#[Route('/console/api-credentials')]
final readonly class ConsoleApiCredentialController
{
    private const int MAX_REQUEST_BYTES = 4096;
    private const int MAX_ACTIVE_CREDENTIALS = 20;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
    ) {
    }

    #[Route(
        '',
        name: 'console_api_credentials_list',
        methods: ['GET'],
    )]
    public function list(
        Request $request,
    ): JsonResponse {
        $access = $this->access(
            $request,
        );

        if ($access instanceof JsonResponse) {
            return $access;
        }

        return new JsonResponse([
            'items'
                => $this
                    ->credentialRows(
                        $access['workspaceId'],
                    ),
        ]);
    }

    #[Route(
        '',
        name: 'console_api_credentials_create',
        methods: ['POST'],
    )]
    public function create(
        Request $request,
    ): JsonResponse {
        $access = $this->access(
            $request,
        );

        if ($access instanceof JsonResponse) {
            return $access;
        }

        $payload = self::jsonObject(
            $request,
        );

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        if (
            array_keys($payload)
            !== [
                'label',
            ]
            || !is_string(
                $payload['label'],
            )
        ) {
            return self::error(
                'invalid_payload',
                'Expected label.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $label = self::label(
                $payload['label'],
            );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_label',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $active = $this
            ->connection
            ->fetchOne(
                <<<'SQL'
SELECT COUNT(*)
FROM api_credential
WHERE workspace_id = :workspace_id
  AND revoked_at IS NULL
SQL,
                [
                    'workspace_id'
                        => $access['workspaceId'],
                ],
            );

        if (
            !is_int($active)
            && !is_string($active)
        ) {
            throw new RuntimeException(
                'Unable to count active API credentials.',
            );
        }

        if ((int) $active >= self::MAX_ACTIVE_CREDENTIALS) {
            return self::error(
                'credential_limit',
                'The workspace already has the maximum number of active API credentials.',
                Response::HTTP_CONFLICT,
            );
        }

        $created = $this
            ->createCredential(
                $access['workspaceId'],
                $label,
            );

        $response = new JsonResponse(
            [
                'credential'
                    => $this
                        ->credentialById(
                            $access['workspaceId'],
                            $created['id'],
                        ),
                'secret'
                    => $created['secret'],
            ],
            Response::HTTP_CREATED,
        );

        $response
            ->headers
            ->set(
                'Cache-Control',
                'no-store',
            );

        return $response;
    }

    #[Route(
        '/{id}/rotate',
        name: 'console_api_credentials_rotate',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['POST'],
    )]
    public function rotate(
        Request $request,
        string $id,
    ): JsonResponse {
        $access = $this->access(
            $request,
        );

        if ($access instanceof JsonResponse) {
            return $access;
        }

        $credentialId = self::positiveId(
            $id,
        );

        if ($credentialId === null) {
            return self::notFound();
        }

        $row = $this
            ->connection
            ->fetchAssociative(
                <<<'SQL'
SELECT
    id,
    revoked_at
FROM api_credential
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
                [
                    'id'
                        => $credentialId,
                    'workspace_id'
                        => $access['workspaceId'],
                ],
            );

        if ($row === false) {
            return self::notFound();
        }

        if ($row['revoked_at'] !== null) {
            return self::error(
                'credential_revoked',
                'A revoked API credential cannot be rotated.',
                Response::HTTP_CONFLICT,
            );
        }

        $secret = bin2hex(
            random_bytes(32),
        );

        $secretHash = password_hash(
            $secret,
            PASSWORD_DEFAULT,
        );

        if (!is_string($secretHash)) {
            throw new RuntimeException(
                'Unable to hash API credential secret.',
            );
        }

        $updated = $this
            ->connection
            ->executeStatement(
                <<<'SQL'
UPDATE api_credential
SET
    secret_hash = :secret_hash,
    last_used_at = NULL
WHERE id = :id
  AND workspace_id = :workspace_id
  AND revoked_at IS NULL
SQL,
                [
                    'secret_hash'
                        => $secretHash,
                    'id'
                        => $credentialId,
                    'workspace_id'
                        => $access['workspaceId'],
                ],
            );

        if ($updated !== 1) {
            return self::notFound();
        }

        $response = new JsonResponse([
            'credential'
                => $this
                    ->credentialById(
                        $access['workspaceId'],
                        $credentialId,
                    ),
            'secret'
                => $secret,
        ]);

        $response
            ->headers
            ->set(
                'Cache-Control',
                'no-store',
            );

        return $response;
    }

    #[Route(
        '/{id}',
        name: 'console_api_credentials_revoke',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['DELETE'],
    )]
    public function revoke(
        Request $request,
        string $id,
    ): Response {
        $access = $this->access(
            $request,
        );

        if ($access instanceof JsonResponse) {
            return $access;
        }

        $credentialId = self::positiveId(
            $id,
        );

        if ($credentialId === null) {
            return self::notFound();
        }

        $exists = $this
            ->connection
            ->fetchOne(
                <<<'SQL'
SELECT COUNT(*)
FROM api_credential
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
                [
                    'id'
                        => $credentialId,
                    'workspace_id'
                        => $access['workspaceId'],
                ],
            );

        if ((int) $exists !== 1) {
            return self::notFound();
        }

        $this
            ->connection
            ->executeStatement(
                <<<'SQL'
UPDATE api_credential
SET revoked_at = COALESCE(
    revoked_at,
    :revoked_at
)
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
                [
                    'revoked_at'
                        => self::now()
                            ->format(
                                'Y-m-d H:i:s',
                            ),
                    'id'
                        => $credentialId,
                    'workspace_id'
                        => $access['workspaceId'],
                ],
            );

        return new Response(
            '',
            Response::HTTP_NO_CONTENT,
        );
    }

    /**
     * @return array{
     *     workspaceId: int,
     *     role: string
     * }|JsonResponse
     */
    private function access(
        Request $request,
    ): array|JsonResponse {
        $user = $this
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

        $memberships = $this
            ->connection
            ->fetchAllAssociative(
                <<<'SQL'
SELECT
    workspace_id,
    role
FROM workspace_member
WHERE user_id = :user_id
ORDER BY workspace_id ASC
LIMIT 2
SQL,
                [
                    'user_id'
                        => $user['id'],
                ],
            );

        if (count($memberships) !== 1) {
            throw new RuntimeException(
                'Expected exactly one console workspace membership.',
            );
        }

        $workspaceId = self::positiveId(
            $memberships[0]['workspace_id']
            ?? null,
        );

        $role =
            $memberships[0]['role']
            ?? null;

        if (
            $workspaceId === null
            || !is_string($role)
            || !in_array(
                $role,
                [
                    'owner',
                    'admin',
                    'member',
                ],
                true,
            )
        ) {
            throw new RuntimeException(
                'Console workspace membership is invalid.',
            );
        }

        if (
            $role !== 'owner'
            && $role !== 'admin'
        ) {
            return self::error(
                'workspace_forbidden',
                'Workspace owner or admin access is required.',
                Response::HTTP_FORBIDDEN,
            );
        }

        return [
            'workspaceId'
                => $workspaceId,
            'role'
                => $role,
        ];
    }

    /**
     * @return array{
     *     id: int,
     *     secret: string
     * }
     */
    private function createCredential(
        int $workspaceId,
        string $label,
    ): array {
        for ($attempt = 0; $attempt < 5; ++$attempt) {
            $apiKey =
                'hm_'
                . bin2hex(
                    random_bytes(16),
                );

            $secret = bin2hex(
                random_bytes(32),
            );

            $secretHash = password_hash(
                $secret,
                PASSWORD_DEFAULT,
            );

            if (!is_string($secretHash)) {
                throw new RuntimeException(
                    'Unable to hash API credential secret.',
                );
            }

            try {
                $id = $this
                    ->connection
                    ->fetchOne(
                        <<<'SQL'
INSERT INTO api_credential (
    workspace_id,
    api_key,
    key_fingerprint,
    secret_hash,
    label,
    created_at
)
VALUES (
    :workspace_id,
    :api_key,
    :fingerprint,
    :secret_hash,
    :label,
    :created_at
)
RETURNING id
SQL,
                        [
                            'workspace_id'
                                => $workspaceId,
                            'api_key'
                                => $apiKey,
                            'fingerprint'
                                => hash(
                                    'sha256',
                                    $apiKey,
                                ),
                            'secret_hash'
                                => $secretHash,
                            'label'
                                => $label,
                            'created_at'
                                => self::now()
                                    ->format(
                                        'Y-m-d H:i:s',
                                    ),
                        ],
                    );
            } catch (UniqueConstraintViolationException) {
                continue;
            }

            $credentialId = self::positiveId(
                $id,
            );

            if ($credentialId === null) {
                throw new RuntimeException(
                    'Database did not return a valid API credential identifier.',
                );
            }

            return [
                'id'
                    => $credentialId,
                'secret'
                    => $secret,
            ];
        }

        throw new RuntimeException(
            'Unable to allocate a unique API credential.',
        );
    }

    /**
     * @return list<array<string, mixed>>
     */
    private function credentialRows(
        int $workspaceId,
    ): array {
        $rows = $this
            ->connection
            ->fetchAllAssociative(
                <<<'SQL'
SELECT
    id,
    api_key,
    key_fingerprint,
    label,
    created_at,
    last_used_at,
    revoked_at
FROM api_credential
WHERE workspace_id = :workspace_id
ORDER BY id DESC
LIMIT 100
SQL,
                [
                    'workspace_id'
                        => $workspaceId,
                ],
            );

        return array_map(
            self::serializeCredential(...),
            $rows,
        );
    }

    /**
     * @return array<string, mixed>
     */
    private function credentialById(
        int $workspaceId,
        int $credentialId,
    ): array {
        $row = $this
            ->connection
            ->fetchAssociative(
                <<<'SQL'
SELECT
    id,
    api_key,
    key_fingerprint,
    label,
    created_at,
    last_used_at,
    revoked_at
FROM api_credential
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
                [
                    'id'
                        => $credentialId,
                    'workspace_id'
                        => $workspaceId,
                ],
            );

        if ($row === false) {
            throw new RuntimeException(
                'Created API credential cannot be read.',
            );
        }

        return self::serializeCredential(
            $row,
        );
    }

    /**
     * @param array<string, mixed> $row
     *
     * @return array<string, mixed>
     */
    private static function serializeCredential(
        array $row,
    ): array {
        $id = self::positiveId(
            $row['id']
            ?? null,
        );

        $apiKey =
            $row['api_key']
            ?? null;

        $fingerprint =
            $row['key_fingerprint']
            ?? null;

        $label =
            $row['label']
            ?? null;

        if (
            $id === null
            || !is_string($apiKey)
            || preg_match(
                '/^hm_[a-f0-9]{32}$/D',
                $apiKey,
            ) !== 1
            || !is_string($fingerprint)
            || preg_match(
                '/^[a-f0-9]{64}$/D',
                $fingerprint,
            ) !== 1
            || !is_string($label)
        ) {
            throw new RuntimeException(
                'API credential row is invalid.',
            );
        }

        return [
            'id'
                => $id,
            'apiKey'
                => $apiKey,
            'fingerprint'
                => $fingerprint,
            'label'
                => $label,
            'createdAt'
                => self::timestamp(
                    $row['created_at']
                    ?? null,
                ),
            'lastUsedAt'
                => self::nullableTimestamp(
                    $row['last_used_at']
                    ?? null,
                ),
            'revokedAt'
                => self::nullableTimestamp(
                    $row['revoked_at']
                    ?? null,
                ),
        ];
    }

    private static function label(
        string $value,
    ): string {
        $value = trim(
            $value,
        );

        if (
            $value === ''
            || strlen($value) > 100
            || preg_match(
                '/[\x00-\x1F\x7F]/',
                $value,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'API credential label must contain between 1 and 100 printable characters.',
            );
        }

        return $value;
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
                'API credential timestamp is invalid.',
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

    private static function nullableTimestamp(
        mixed $value,
    ): ?string {
        if ($value === null) {
            return null;
        }

        return self::timestamp(
            $value,
        );
    }

    private static function notFound(): JsonResponse
    {
        return self::error(
            'credential_not_found',
            'API credential was not found.',
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

    private static function now(): DateTimeImmutable
    {
        return new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );
    }
}
