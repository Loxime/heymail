<?php

declare(strict_types=1);

namespace App\Controller;

use App\Console\ConsoleAuthentication;
use App\Console\ConsoleUserProvisioner;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use JsonException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/console/profile')]
final readonly class ConsoleProfileController
{
    private const int MAX_REQUEST_BYTES = 16384;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
        private ConsoleUserProvisioner $provisioner,
    ) {
    }

    #[Route(
        '',
        name: 'console_profile_show',
        methods: ['GET'],
    )]
    public function show(
        Request $request,
    ): JsonResponse {
        $user = $this->user(
            $request,
        );

        if ($user instanceof JsonResponse) {
            return $user;
        }

        return new JsonResponse(
            $this->profileDocument(
                $user,
            ),
        );
    }

    #[Route(
        '',
        name: 'console_profile_update',
        methods: ['PATCH'],
    )]
    public function update(
        Request $request,
    ): JsonResponse {
        $user = $this->user(
            $request,
        );

        if ($user instanceof JsonResponse) {
            return $user;
        }

        $payload = self::jsonObject(
            $request,
        );

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        $allowed = [
            'firstName',
            'lastName',
            'email',
        ];

        foreach (array_keys($payload) as $key) {
            if (
                !is_string($key)
                || !in_array(
                    $key,
                    $allowed,
                    true,
                )
            ) {
                return self::error(
                    'invalid_payload',
                    'Unexpected profile field.',
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                );
            }
        }

        $firstName = $user['firstName'];
        $lastName = $user['lastName'];
        $email = $user['email'];

        try {
            if (array_key_exists('firstName', $payload)) {
                $firstName = self::profileName(
                    $payload['firstName'],
                    'firstName',
                );
            }

            if (array_key_exists('lastName', $payload)) {
                $lastName = self::profileName(
                    $payload['lastName'],
                    'lastName',
                );
            }

            if (array_key_exists('email', $payload)) {
                if (!is_string($payload['email'])) {
                    throw new InvalidArgumentException(
                        'Invalid email.',
                    );
                }

                $email = ConsoleAuthentication::normalizeEmail(
                    $payload['email'],
                );
            }
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_profile',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $this->connection
                ->update(
                    'console_user',
                    [
                        'first_name' => $firstName,
                        'last_name' => $lastName,
                        'email' => $email,
                        'updated_at' => self::now()
                            ->format('Y-m-d H:i:s'),
                    ],
                    [
                        'id' => $user['id'],
                    ],
                );
        } catch (\Throwable) {
            return self::error(
                'profile_conflict',
                'This email address is already in use.',
                Response::HTTP_CONFLICT,
            );
        }

        $updated = [
            ...$user,
            'firstName' => $firstName,
            'lastName' => $lastName,
            'email' => $email,
        ];

        return new JsonResponse(
            $this->profileDocument(
                $updated,
            ),
        );
    }

    #[Route(
        '/password',
        name: 'console_profile_password',
        methods: ['POST'],
    )]
    public function password(
        Request $request,
    ): JsonResponse {
        $user = $this->user(
            $request,
        );

        if ($user instanceof JsonResponse) {
            return $user;
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
                'currentPassword',
                'newPassword',
            ]
            || !is_string(
                $payload['currentPassword'],
            )
            || !is_string(
                $payload['newPassword'],
            )
        ) {
            return self::error(
                'invalid_payload',
                'Expected currentPassword and newPassword.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $hash = $this->connection
            ->fetchOne(
                'SELECT password_hash FROM console_user WHERE id = :id',
                [
                    'id' => $user['id'],
                ],
            );

        if (
            !is_string($hash)
            || !password_verify(
                $payload['currentPassword'],
                $hash,
            )
        ) {
            return self::error(
                'invalid_password',
                'Current password is incorrect.',
                Response::HTTP_FORBIDDEN,
            );
        }

        if (
            strlen($payload['newPassword']) < 12
            || strlen($payload['newPassword']) > 4096
        ) {
            return self::error(
                'invalid_password',
                'New password must contain at least 12 characters.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $newHash = password_hash(
            $payload['newPassword'],
            PASSWORD_DEFAULT,
        );

        if (!is_string($newHash)) {
            throw new \RuntimeException(
                'Unable to hash console password.',
            );
        }

        $this->connection
            ->update(
                'console_user',
                [
                    'password_hash' => $newHash,
                    'updated_at' => self::now()
                        ->format('Y-m-d H:i:s'),
                ],
                [
                    'id' => $user['id'],
                ],
            );

        $this->connection
            ->executeStatement(
                'DELETE FROM console_session WHERE user_id = :user_id AND token_hash <> :current_token_hash',
                [
                    'user_id' => $user['id'],
                    'current_token_hash' => hash(
                        'sha256',
                        (string) $request->cookies->get(
                            ConsoleAuthentication::COOKIE_NAME,
                            '',
                        ),
                    ),
                ],
            );

        return new JsonResponse([
            'updated' => true,
        ]);
    }

    #[Route(
        '/favorites',
        name: 'console_profile_favorites',
        methods: ['GET'],
    )]
    public function favorites(
        Request $request,
    ): JsonResponse {
        $user = $this->user(
            $request,
        );

        if ($user instanceof JsonResponse) {
            return $user;
        }

        return new JsonResponse([
            'items' => $this->favoriteRows(
                $user['id'],
            ),
        ]);
    }

    #[Route(
        '/favorites',
        name: 'console_profile_favorite_add',
        methods: ['POST'],
    )]
    public function addFavorite(
        Request $request,
    ): JsonResponse {
        $user = $this->user(
            $request,
        );

        if ($user instanceof JsonResponse) {
            return $user;
        }

        $payload = self::jsonObject(
            $request,
        );

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        foreach (array_keys($payload) as $key) {
            if (
                !is_string($key)
                || !in_array(
                    $key,
                    [
                        'email',
                        'name',
                    ],
                    true,
                )
            ) {
                return self::error(
                    'invalid_payload',
                    'Unexpected favorite contact field.',
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                );
            }
        }

        if (!isset($payload['email']) || !is_string($payload['email'])) {
            return self::error(
                'invalid_payload',
                'Favorite contact email is required.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $email = ConsoleAuthentication::normalizeEmail(
                $payload['email'],
            );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_contact',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $name = $payload['name'] ?? null;

        if ($name !== null) {
            if (!is_string($name)) {
                return self::error(
                    'invalid_contact',
                    'Favorite contact name must be a string.',
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                );
            }

            $name = trim($name);

            if ($name === '') {
                $name = null;
            } elseif (strlen($name) > 160) {
                return self::error(
                    'invalid_contact',
                    'Favorite contact name is too long.',
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                );
            }
        }

        $this->connection
            ->executeStatement(
                <<<'SQL'
INSERT INTO console_favorite_contact (
    user_id,
    email,
    name,
    created_at
)
VALUES (
    :user_id,
    :email,
    :name,
    :created_at
)
ON CONFLICT (user_id, email)
DO UPDATE SET name = EXCLUDED.name
SQL,
                [
                    'user_id' => $user['id'],
                    'email' => $email,
                    'name' => $name,
                    'created_at' => self::now()
                        ->format('Y-m-d H:i:s'),
                ],
            );

        return new JsonResponse([
            'items' => $this->favoriteRows(
                $user['id'],
            ),
        ]);
    }

    #[Route(
        '/favorites/{id}',
        name: 'console_profile_favorite_delete',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['DELETE'],
    )]
    public function deleteFavorite(
        Request $request,
        string $id,
    ): Response {
        $user = $this->user(
            $request,
        );

        if ($user instanceof JsonResponse) {
            return $user;
        }

        $favoriteId = filter_var(
            $id,
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        if (!is_int($favoriteId)) {
            return new Response(
                '',
                Response::HTTP_NOT_FOUND,
            );
        }

        $this->connection
            ->delete(
                'console_favorite_contact',
                [
                    'id' => $favoriteId,
                    'user_id' => $user['id'],
                ],
            );

        return new Response(
            '',
            Response::HTTP_NO_CONTENT,
        );
    }

    #[Route(
        '',
        name: 'console_profile_delete',
        methods: ['DELETE'],
    )]
    public function delete(
        Request $request,
    ): Response {
        $user = $this->user(
            $request,
        );

        if ($user instanceof JsonResponse) {
            return $user;
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
                'password',
                'confirm',
            ]
            || !is_string(
                $payload['password'],
            )
            || $payload['confirm'] !== 'DELETE'
        ) {
            return self::error(
                'invalid_confirmation',
                'Account deletion requires password and confirm=DELETE.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $hash = $this->connection
            ->fetchOne(
                'SELECT password_hash FROM console_user WHERE id = :id',
                [
                    'id' => $user['id'],
                ],
            );

        if (
            !is_string($hash)
            || !password_verify(
                $payload['password'],
                $hash,
            )
        ) {
            return self::error(
                'invalid_password',
                'Password is incorrect.',
                Response::HTTP_FORBIDDEN,
            );
        }

        $this->provisioner
            ->delete(
                $user['id'],
            );

        $response = new Response(
            '',
            Response::HTTP_NO_CONTENT,
        );

        $response->headers->setCookie(
            ConsoleAuthentication::expiredCookie(
                $request->isSecure(),
            ),
        );

        return $response;
    }

    /**
     * @param array{
     *     id: int,
     *     email: string,
     *     firstName: string,
     *     lastName: string
     * } $user
     *
     * @return array<string, mixed>
     */
    private function profileDocument(
        array $user,
    ): array {
        $workspaceId = $this->workspaceIdForUser(
            $user['id'],
        );

        $sentRaw = $this->connection
            ->fetchOne(
                <<<'SQL'
SELECT COUNT(*)
FROM outbound_message
WHERE workspace_id = :workspace_id
SQL,
                [
                    'workspace_id'
                        => $workspaceId,
                ],
            );

        if (
            !is_int($sentRaw)
            && !is_string($sentRaw)
        ) {
            throw new \RuntimeException(
                'Unable to read workspace outbound message count.',
            );
        }

        $workspaceSent = (int) $sentRaw;

        $favoritesRaw = $this->connection
            ->fetchOne(
                'SELECT COUNT(*) FROM console_favorite_contact WHERE user_id = :user_id',
                [
                    'user_id' => $user['id'],
                ],
            );

        if (
            !is_int($favoritesRaw)
            && !is_string($favoritesRaw)
        ) {
            throw new \RuntimeException(
                'Unable to read favorite contact count.',
            );
        }

        $favorites = (int) $favoritesRaw;

        return [
            'user' => $user,
            'stats' => [
                'messagesSent' => $workspaceSent,
                'messagesSentScope' => 'workspace',
                'messagesReceived' => 0,
                'messagesReceivedAvailable' => false,
                'favoriteContacts' => $favorites,
            ],
            'favorites' => $this->favoriteRows(
                $user['id'],
            ),
        ];
    }

    private function workspaceIdForUser(
        int $userId,
    ): int {
        $workspaceIds =
            $this->connection
                ->fetchFirstColumn(
                    <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
ORDER BY workspace_id ASC
LIMIT 2
SQL,
                    [
                        'user_id'
                            => $userId,
                    ],
                );

        if (count($workspaceIds) !== 1) {
            throw new \RuntimeException(
                'Expected exactly one console workspace membership.',
            );
        }

        $workspaceId = filter_var(
            $workspaceIds[0],
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        if (!is_int($workspaceId)) {
            throw new \RuntimeException(
                'Console workspace has an invalid identifier.',
            );
        }

        return $workspaceId;
    }

    /**
     * @return list<array{
     *     id: int,
     *     email: string,
     *     name: string|null,
     *     createdAt: string
     * }>
     */
    private function favoriteRows(
        int $userId,
    ): array {
        $rows = $this->connection
            ->fetchAllAssociative(
                <<<'SQL'
SELECT
    id,
    email,
    name,
    created_at
FROM console_favorite_contact
WHERE user_id = :user_id
ORDER BY id DESC
LIMIT 100
SQL,
                [
                    'user_id' => $userId,
                ],
            );

        return array_map(
            static function (array $row): array {
                return [
                    'id' => (int) $row['id'],
                    'email' => (string) $row['email'],
                    'name' => $row['name'] === null
                        ? null
                        : (string) $row['name'],
                    'createdAt' => (new DateTimeImmutable(
                        (string) $row['created_at'],
                        new DateTimeZone('UTC'),
                    ))->format(DATE_ATOM),
                ];
            },
            $rows,
        );
    }

    /**
     * @return array{
     *     id: int,
     *     email: string,
     *     firstName: string,
     *     lastName: string
     * }|JsonResponse
     */
    private function user(
        Request $request,
    ): array|JsonResponse {
        return $this->authentication
            ->authenticate(
                $request,
            )
            ?? self::error(
                'console_unauthorized',
                'Console authentication required.',
                Response::HTTP_UNAUTHORIZED,
            );
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
                16,
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

    private static function profileName(
        mixed $value,
        string $label,
    ): string {
        if (!is_string($value)) {
            throw new InvalidArgumentException(
                sprintf(
                    '%s must be a string.',
                    $label,
                ),
            );
        }

        $value = trim($value);

        if (
            $value === ''
            || strlen($value) > 100
            || preg_match('/[\x00-\x1F\x7F]/', $value) === 1
        ) {
            throw new InvalidArgumentException(
                sprintf(
                    'Invalid %s.',
                    $label,
                ),
            );
        }

        return $value;
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
