<?php

declare(strict_types=1);

namespace App\Controller;

use App\Automation\ContactAddedAutomationTrigger;
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

#[Route('/console')]
final readonly class ConsoleContactController
{
    private const int MAX_REQUEST_BYTES = 65536;
    private const int MAX_CONTACTS_PER_PAGE = 100;
    private const int MAX_TAGS_PER_CONTACT = 50;
    private const int MAX_LISTS_PER_CONTACT = 100;
    private const int MAX_CUSTOM_FIELDS = 50;
    private const int MAX_CUSTOM_FIELDS_BYTES = 16384;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
        private ContactAddedAutomationTrigger $automationTrigger,
    ) {
    }

    #[Route('/contacts', name: 'console_contacts_list', methods: ['GET'])]
    public function contacts(Request $request): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $query = $request->query->all();
        $allowed = ['q', 'tag', 'list', 'limit'];

        foreach (array_keys($query) as $key) {
            if (!is_string($key) || !in_array($key, $allowed, true)) {
                return self::error(
                    'invalid_query',
                    'Unexpected contact query parameter.',
                    Response::HTTP_BAD_REQUEST,
                );
            }
        }

        foreach ($query as $value) {
            if (!is_string($value)) {
                return self::error(
                    'invalid_query',
                    'Contact query parameters must be scalar strings.',
                    Response::HTTP_BAD_REQUEST,
                );
            }
        }

        $limitRaw = $query['limit'] ?? '50';

        if (
            preg_match('/^[1-9][0-9]{0,2}$/D', $limitRaw) !== 1
            || (int) $limitRaw > self::MAX_CONTACTS_PER_PAGE
        ) {
            return self::error(
                'invalid_query',
                'limit must be between 1 and 100.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        $where = [
            'c.workspace_id = :workspace_id',
        ];

        $params = [
            'workspace_id' => $workspaceId,
            'limit' => (int) $limitRaw,
        ];

        if (isset($query['q'])) {
            $q = trim($query['q']);

            if ($q === '' || strlen($q) > 160) {
                return self::error(
                    'invalid_query',
                    'q must contain between 1 and 160 characters.',
                    Response::HTTP_BAD_REQUEST,
                );
            }

            $where[] = <<<'SQL'
(
    lower(c.email) LIKE :q
    OR lower(COALESCE(c.name, '')) LIKE :q
)
SQL;
            $params['q'] = '%' . strtolower($q) . '%';
        }

        if (isset($query['tag'])) {
            try {
                $tag = self::tagName($query['tag']);
            } catch (InvalidArgumentException $exception) {
                return self::error(
                    'invalid_query',
                    $exception->getMessage(),
                    Response::HTTP_BAD_REQUEST,
                );
            }

            $where[] = <<<'SQL'
EXISTS (
    SELECT 1
    FROM contact_tag_assignment a
    INNER JOIN contact_tag t
        ON t.workspace_id = a.workspace_id
       AND t.id = a.tag_id
    WHERE a.workspace_id = c.workspace_id
      AND a.contact_id = c.id
      AND lower(t.name) = lower(:tag)
)
SQL;
            $params['tag'] = $tag;
        }

        if (isset($query['list'])) {
            $listId = self::positiveId($query['list']);

            if ($listId === null) {
                return self::error(
                    'invalid_query',
                    'list must be a positive identifier.',
                    Response::HTTP_BAD_REQUEST,
                );
            }

            $where[] = <<<'SQL'
EXISTS (
    SELECT 1
    FROM contact_list_member m
    WHERE m.workspace_id = c.workspace_id
      AND m.contact_id = c.id
      AND m.list_id = :list_id
)
SQL;
            $params['list_id'] = $listId;
        }

        $sql = sprintf(
            <<<'SQL'
SELECT
    c.id,
    c.email,
    c.name,
    c.custom_fields,
    c.created_at,
    c.updated_at,
    COALESCE(
        (
            SELECT json_agg(t.name ORDER BY lower(t.name), t.id)
            FROM contact_tag_assignment a
            INNER JOIN contact_tag t
                ON t.workspace_id = a.workspace_id
               AND t.id = a.tag_id
            WHERE a.workspace_id = c.workspace_id
              AND a.contact_id = c.id
        ),
        '[]'::json
    ) AS tags,
    COALESCE(
        (
            SELECT json_agg(m.list_id ORDER BY m.list_id)
            FROM contact_list_member m
            WHERE m.workspace_id = c.workspace_id
              AND m.contact_id = c.id
        ),
        '[]'::json
    ) AS list_ids
FROM contact c
WHERE %s
ORDER BY c.id DESC
LIMIT :limit
SQL,
            implode("\nAND ", $where),
        );

        $rows = $this->connection->fetchAllAssociative($sql, $params);

        return new JsonResponse([
            'items' => array_map(
                self::serializeContact(...),
                $rows,
            ),
        ]);
    }

    #[Route('/contacts', name: 'console_contacts_create', methods: ['POST'])]
    public function createContact(Request $request): JsonResponse
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
            self::assertAllowedContactFields($payload, true);

            $email = self::email($payload['email']);
            $name = self::contactName($payload['name'] ?? null);
            $customFields = self::customFields(
                $payload['customFields'] ?? [],
            );
            $tags = self::tags($payload['tags'] ?? []);
            $listIds = self::listIds($payload['listIds'] ?? []);
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_contact',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $this->connection->beginTransaction();

        try {
            $now = self::now()->format('Y-m-d H:i:s');

            $contactId = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
INSERT INTO contact (
    workspace_id,
    email,
    name,
    custom_fields,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :email,
    :name,
    CAST(:custom_fields AS jsonb),
    :created_at,
    :updated_at
)
RETURNING id
SQL,
                    [
                        'workspace_id' => $workspaceId,
                        'email' => $email,
                        'name' => $name,
                        'custom_fields' => json_encode(
                            $customFields,
                            JSON_THROW_ON_ERROR | JSON_FORCE_OBJECT,
                        ),
                        'created_at' => $now,
                        'updated_at' => $now,
                    ],
                ),
            );

            if ($contactId === null) {
                throw new RuntimeException(
                    'Contact identifier is invalid.',
                );
            }

            $this->replaceTags(
                $workspaceId,
                $contactId,
                $tags,
                $now,
            );

            $this->replaceLists(
                $workspaceId,
                $contactId,
                $listIds,
                $now,
            );

            $this->automationTrigger->enqueue(
                $workspaceId,
                $contactId,
            );

            $this->connection->commit();
        } catch (UniqueConstraintViolationException) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            return self::error(
                'contact_conflict',
                'A contact with this email already exists in the workspace.',
                Response::HTTP_CONFLICT,
            );
        } catch (\Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }

        return new JsonResponse(
            $this->contactById($workspaceId, $contactId),
            Response::HTTP_CREATED,
        );
    }

    #[Route(
        '/contacts/{id}',
        name: 'console_contacts_update',
        requirements: ['id' => '[1-9][0-9]*'],
        methods: ['PATCH'],
    )]
    public function updateContact(
        Request $request,
        string $id,
    ): JsonResponse {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $contactId = self::positiveId($id);

        if ($contactId === null) {
            return self::notFound('contact');
        }

        $payload = self::jsonObject($request);

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        try {
            self::assertAllowedContactFields($payload, false);

            $email = array_key_exists('email', $payload)
                ? self::email($payload['email'])
                : null;

            $name = array_key_exists('name', $payload)
                ? self::contactName($payload['name'])
                : null;

            $customFields = array_key_exists('customFields', $payload)
                ? self::customFields($payload['customFields'])
                : null;

            $tags = array_key_exists('tags', $payload)
                ? self::tags($payload['tags'])
                : null;

            $listIds = array_key_exists('listIds', $payload)
                ? self::listIds($payload['listIds'])
                : null;
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_contact',
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
FROM contact
WHERE id = :id
  AND workspace_id = :workspace_id
FOR UPDATE
SQL,
                    [
                        'id' => $contactId,
                        'workspace_id' => $workspaceId,
                    ],
                ),
            );

            if ($owned === null) {
                $this->connection->rollBack();
                return self::notFound('contact');
            }

            $changes = [];

            if (array_key_exists('email', $payload)) {
                $changes['email'] = $email;
            }

            if (array_key_exists('name', $payload)) {
                $changes['name'] = $name;
            }

            if ($customFields !== null) {
                $changes['custom_fields'] = json_encode(
                    $customFields,
                    JSON_THROW_ON_ERROR | JSON_FORCE_OBJECT,
                );
            }

            $now = self::now()->format('Y-m-d H:i:s');

            if (
                $changes !== []
                || $tags !== null
                || $listIds !== null
            ) {
                $changes['updated_at'] = $now;
            }

            if ($changes !== []) {
                $this->connection->update(
                    'contact',
                    $changes,
                    [
                        'id' => $contactId,
                        'workspace_id' => $workspaceId,
                    ],
                );
            }

            if ($tags !== null) {
                $this->replaceTags(
                    $workspaceId,
                    $contactId,
                    $tags,
                    $now,
                );
            }

            if ($listIds !== null) {
                $this->replaceLists(
                    $workspaceId,
                    $contactId,
                    $listIds,
                    $now,
                );
            }

            $this->connection->commit();
        } catch (UniqueConstraintViolationException) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            return self::error(
                'contact_conflict',
                'A contact with this email already exists in the workspace.',
                Response::HTTP_CONFLICT,
            );
        } catch (\Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }

        return new JsonResponse(
            $this->contactById($workspaceId, $contactId),
        );
    }

    #[Route(
        '/contacts/{id}',
        name: 'console_contacts_delete',
        requirements: ['id' => '[1-9][0-9]*'],
        methods: ['DELETE'],
    )]
    public function deleteContact(
        Request $request,
        string $id,
    ): Response {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $contactId = self::positiveId($id);

        if ($contactId === null) {
            return self::notFound('contact');
        }

        $deleted = $this->connection->delete(
            'contact',
            [
                'id' => $contactId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($deleted !== 1) {
            return self::notFound('contact');
        }

        return new Response('', Response::HTTP_NO_CONTENT);
    }

    #[Route(
        '/contact-lists',
        name: 'console_contact_lists',
        methods: ['GET'],
    )]
    public function lists(Request $request): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $rows = $this->connection->fetchAllAssociative(
            <<<'SQL'
SELECT
    l.id,
    l.name,
    l.created_at,
    l.updated_at,
    COUNT(m.contact_id) AS contact_count
FROM contact_list l
LEFT JOIN contact_list_member m
    ON m.workspace_id = l.workspace_id
   AND m.list_id = l.id
WHERE l.workspace_id = :workspace_id
GROUP BY
    l.id,
    l.name,
    l.created_at,
    l.updated_at
ORDER BY lower(l.name), l.id
SQL,
            [
                'workspace_id' => $workspaceId,
            ],
        );

        return new JsonResponse([
            'items' => array_map(
                static fn (array $row): array => [
                    'id' => (int) $row['id'],
                    'name' => (string) $row['name'],
                    'contactCount' => (int) $row['contact_count'],
                    'createdAt' => self::timestamp($row['created_at']),
                    'updatedAt' => self::timestamp($row['updated_at']),
                ],
                $rows,
            ),
        ]);
    }

    #[Route(
        '/contact-lists',
        name: 'console_contact_lists_create',
        methods: ['POST'],
    )]
    public function createList(Request $request): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $payload = self::jsonObject($request);

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        if (array_keys($payload) !== ['name']) {
            return self::error(
                'invalid_list',
                'Expected contact list name.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $name = self::listName($payload['name']);
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_list',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $now = self::now()->format('Y-m-d H:i:s');

            $listId = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
INSERT INTO contact_list (
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
        } catch (UniqueConstraintViolationException) {
            return self::error(
                'list_conflict',
                'A contact list with this name already exists.',
                Response::HTTP_CONFLICT,
            );
        }

        if ($listId === null) {
            throw new RuntimeException(
                'Contact list identifier is invalid.',
            );
        }

        return new JsonResponse(
            [
                'id' => $listId,
                'name' => $name,
                'contactCount' => 0,
                'createdAt' => self::timestamp($now),
                'updatedAt' => self::timestamp($now),
            ],
            Response::HTTP_CREATED,
        );
    }

    #[Route(
        '/contact-lists/{id}/members',
        name: 'console_contact_lists_members',
        requirements: ['id' => '[1-9][0-9]*'],
        methods: ['POST'],
    )]
    public function replaceListMembers(
        Request $request,
        string $id,
    ): JsonResponse {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $listId = self::positiveId($id);

        if ($listId === null) {
            return self::notFound('list');
        }

        $payload = self::jsonObject($request);

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        if (array_keys($payload) !== ['contactIds']) {
            return self::error(
                'invalid_list_members',
                'Expected contactIds.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $contactIds = self::listIds(
                $payload['contactIds'],
            );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_list_members',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $this->connection->beginTransaction();

        try {
            $ownedList = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
SELECT id
FROM contact_list
WHERE id = :id
  AND workspace_id = :workspace_id
FOR UPDATE
SQL,
                    [
                        'id' => $listId,
                        'workspace_id' => $workspaceId,
                    ],
                ),
            );

            if ($ownedList === null) {
                $this->connection->rollBack();
                return self::notFound('list');
            }

            $this->assertOwnedContacts(
                $workspaceId,
                $contactIds,
            );

            $this->connection->delete(
                'contact_list_member',
                [
                    'workspace_id' => $workspaceId,
                    'list_id' => $listId,
                ],
            );

            $now = self::now()->format('Y-m-d H:i:s');

            foreach ($contactIds as $contactId) {
                $this->connection->insert(
                    'contact_list_member',
                    [
                        'workspace_id' => $workspaceId,
                        'list_id' => $listId,
                        'contact_id' => $contactId,
                        'created_at' => $now,
                    ],
                );
            }

            $this->connection->update(
                'contact_list',
                [
                    'updated_at' => $now,
                ],
                [
                    'id' => $listId,
                    'workspace_id' => $workspaceId,
                ],
            );

            $this->connection->commit();
        } catch (InvalidArgumentException $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            return self::error(
                'invalid_list_members',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        } catch (\Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }

        return new JsonResponse([
            'id' => $listId,
            'contactCount' => count($contactIds),
        ]);
    }

    #[Route(
        '/contact-lists/{id}',
        name: 'console_contact_lists_delete',
        requirements: ['id' => '[1-9][0-9]*'],
        methods: ['DELETE'],
    )]
    public function deleteList(
        Request $request,
        string $id,
    ): Response {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $listId = self::positiveId($id);

        if ($listId === null) {
            return self::notFound('list');
        }

        $deleted = $this->connection->delete(
            'contact_list',
            [
                'id' => $listId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($deleted !== 1) {
            return self::notFound('list');
        }

        return new Response('', Response::HTTP_NO_CONTENT);
    }

    private function workspaceId(
        Request $request,
    ): int|JsonResponse {
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
            [
                'user_id' => $user['id'],
            ],
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

    /**
     * @param list<string> $tags
     */
    private function replaceTags(
        int $workspaceId,
        int $contactId,
        array $tags,
        string $now,
    ): void {
        $this->connection->delete(
            'contact_tag_assignment',
            [
                'workspace_id' => $workspaceId,
                'contact_id' => $contactId,
            ],
        );

        foreach ($tags as $tag) {
            $this->connection->executeStatement(
                <<<'SQL'
INSERT INTO contact_tag (
    workspace_id,
    name,
    created_at
)
VALUES (
    :workspace_id,
    :name,
    :created_at
)
ON CONFLICT DO NOTHING
SQL,
                [
                    'workspace_id' => $workspaceId,
                    'name' => $tag,
                    'created_at' => $now,
                ],
            );

            $tagId = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
SELECT id
FROM contact_tag
WHERE workspace_id = :workspace_id
  AND lower(name) = lower(:name)
SQL,
                    [
                        'workspace_id' => $workspaceId,
                        'name' => $tag,
                    ],
                ),
            );

            if ($tagId === null) {
                throw new RuntimeException(
                    'Unable to resolve contact tag.',
                );
            }

            $this->connection->insert(
                'contact_tag_assignment',
                [
                    'workspace_id' => $workspaceId,
                    'contact_id' => $contactId,
                    'tag_id' => $tagId,
                    'created_at' => $now,
                ],
            );
        }
    }

    /**
     * @param list<int> $listIds
     */
    private function replaceLists(
        int $workspaceId,
        int $contactId,
        array $listIds,
        string $now,
    ): void {
        $this->assertOwnedLists(
            $workspaceId,
            $listIds,
        );

        $this->connection->delete(
            'contact_list_member',
            [
                'workspace_id' => $workspaceId,
                'contact_id' => $contactId,
            ],
        );

        foreach ($listIds as $listId) {
            $this->connection->insert(
                'contact_list_member',
                [
                    'workspace_id' => $workspaceId,
                    'list_id' => $listId,
                    'contact_id' => $contactId,
                    'created_at' => $now,
                ],
            );
        }
    }

    /**
     * @param list<int> $ids
     */
    private function assertOwnedLists(
        int $workspaceId,
        array $ids,
    ): void {
        if ($ids === []) {
            return;
        }

        $owned = $this->connection->fetchFirstColumn(
            <<<'SQL'
SELECT id
FROM contact_list
WHERE workspace_id = :workspace_id
  AND id = ANY(CAST(:ids AS bigint[]))
ORDER BY id
SQL,
            [
                'workspace_id' => $workspaceId,
                'ids' => '{' . implode(',', $ids) . '}',
            ],
        );

        if (count($owned) !== count($ids)) {
            throw new InvalidArgumentException(
                'One or more contact lists do not belong to the workspace.',
            );
        }
    }

    /**
     * @param list<int> $ids
     */
    private function assertOwnedContacts(
        int $workspaceId,
        array $ids,
    ): void {
        if ($ids === []) {
            return;
        }

        $owned = $this->connection->fetchFirstColumn(
            <<<'SQL'
SELECT id
FROM contact
WHERE workspace_id = :workspace_id
  AND id = ANY(CAST(:ids AS bigint[]))
ORDER BY id
SQL,
            [
                'workspace_id' => $workspaceId,
                'ids' => '{' . implode(',', $ids) . '}',
            ],
        );

        if (count($owned) !== count($ids)) {
            throw new InvalidArgumentException(
                'One or more contacts do not belong to the workspace.',
            );
        }
    }

    /**
     * @return array<string, mixed>
     */
    private function contactById(
        int $workspaceId,
        int $contactId,
    ): array {
        $row = $this->connection->fetchAssociative(
            <<<'SQL'
SELECT
    c.id,
    c.email,
    c.name,
    c.custom_fields,
    c.created_at,
    c.updated_at,
    COALESCE(
        (
            SELECT json_agg(t.name ORDER BY lower(t.name), t.id)
            FROM contact_tag_assignment a
            INNER JOIN contact_tag t
                ON t.workspace_id = a.workspace_id
               AND t.id = a.tag_id
            WHERE a.workspace_id = c.workspace_id
              AND a.contact_id = c.id
        ),
        '[]'::json
    ) AS tags,
    COALESCE(
        (
            SELECT json_agg(m.list_id ORDER BY m.list_id)
            FROM contact_list_member m
            WHERE m.workspace_id = c.workspace_id
              AND m.contact_id = c.id
        ),
        '[]'::json
    ) AS list_ids
FROM contact c
WHERE c.id = :id
  AND c.workspace_id = :workspace_id
SQL,
            [
                'id' => $contactId,
                'workspace_id' => $workspaceId,
            ],
        );

        if ($row === false) {
            throw new RuntimeException(
                'Contact cannot be read after mutation.',
            );
        }

        return self::serializeContact($row);
    }

    /**
     * @param array<string, mixed> $row
     *
     * @return array<string, mixed>
     */
    private static function serializeContact(
        array $row,
    ): array {
        $customFields = self::decodeObject(
            $row['custom_fields'] ?? '{}',
            'contact custom fields',
        );

        $tags = self::decodeList(
            $row['tags'] ?? '[]',
            'contact tags',
        );

        $listIds = array_map(
            static fn (mixed $value): int => (int) $value,
            self::decodeList(
                $row['list_ids'] ?? '[]',
                'contact list identifiers',
            ),
        );

        return [
            'id' => (int) $row['id'],
            'email' => (string) $row['email'],
            'name' => $row['name'] === null
                ? null
                : (string) $row['name'],
            'customFields' => $customFields === []
                ? new \stdClass()
                : $customFields,
            'tags' => $tags,
            'listIds' => $listIds,
            'createdAt' => self::timestamp($row['created_at']),
            'updatedAt' => self::timestamp($row['updated_at']),
        ];
    }

    /**
     * @param array<string, mixed> $payload
     */
    private static function assertAllowedContactFields(
        array $payload,
        bool $creating,
    ): void {
        if ($payload === []) {
            throw new InvalidArgumentException(
                'Contact payload cannot be empty.',
            );
        }

        $allowed = [
            'email',
            'name',
            'customFields',
            'tags',
            'listIds',
        ];

        foreach (array_keys($payload) as $key) {
            if (!is_string($key) || !in_array($key, $allowed, true)) {
                throw new InvalidArgumentException(
                    'Unexpected contact field.',
                );
            }
        }

        if ($creating && !array_key_exists('email', $payload)) {
            throw new InvalidArgumentException(
                'Contact email is required.',
            );
        }
    }

    private static function email(
        mixed $value,
    ): string {
        if (!is_string($value)) {
            throw new InvalidArgumentException(
                'Contact email is required.',
            );
        }

        return ConsoleAuthentication::normalizeEmail(
            $value,
        );
    }

    private static function contactName(
        mixed $value,
    ): ?string {
        if ($value === null) {
            return null;
        }

        if (!is_string($value)) {
            throw new InvalidArgumentException(
                'Contact name must be a string or null.',
            );
        }

        $value = trim($value);

        if ($value === '') {
            return null;
        }

        if (
            strlen($value) > 160
            || preg_match('/[\x00-\x1F\x7F]/', $value) === 1
        ) {
            throw new InvalidArgumentException(
                'Contact name is invalid.',
            );
        }

        return $value;
    }

    /**
     * @return array<string, scalar|null>
     */
    private static function customFields(
        mixed $value,
    ): array {
        if (
            !is_array($value)
            || ($value !== [] && array_is_list($value))
        ) {
            throw new InvalidArgumentException(
                'customFields must be a JSON object.',
            );
        }

        if (count($value) > self::MAX_CUSTOM_FIELDS) {
            throw new InvalidArgumentException(
                'Too many custom contact fields.',
            );
        }

        $normalized = [];

        foreach ($value as $key => $fieldValue) {
            if (
                !is_string($key)
                || preg_match(
                    '/^[a-z][a-z0-9_]{0,63}$/D',
                    $key,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'Invalid custom contact field name.',
                );
            }

            if (
                !is_string($fieldValue)
                && !is_int($fieldValue)
                && !is_float($fieldValue)
                && !is_bool($fieldValue)
                && $fieldValue !== null
            ) {
                throw new InvalidArgumentException(
                    'Custom contact field values must be scalar or null.',
                );
            }

            if (
                is_string($fieldValue)
                && strlen($fieldValue) > 4096
            ) {
                throw new InvalidArgumentException(
                    'Custom contact field value is too long.',
                );
            }

            $normalized[$key] = $fieldValue;
        }

        $encoded = json_encode(
            $normalized,
            JSON_THROW_ON_ERROR,
        );

        if (strlen($encoded) > self::MAX_CUSTOM_FIELDS_BYTES) {
            throw new InvalidArgumentException(
                'Custom contact fields are too large.',
            );
        }

        return $normalized;
    }

    /**
     * @return list<string>
     */
    private static function tags(
        mixed $value,
    ): array {
        if (!is_array($value) || !array_is_list($value)) {
            throw new InvalidArgumentException(
                'tags must be a list.',
            );
        }

        if (count($value) > self::MAX_TAGS_PER_CONTACT) {
            throw new InvalidArgumentException(
                'Too many contact tags.',
            );
        }

        $result = [];
        $seen = [];

        foreach ($value as $tag) {
            $tag = self::tagName($tag);
            $normalized = strtolower($tag);

            if (isset($seen[$normalized])) {
                continue;
            }

            $seen[$normalized] = true;
            $result[] = $tag;
        }

        return $result;
    }

    private static function tagName(
        mixed $value,
    ): string {
        if (!is_string($value)) {
            throw new InvalidArgumentException(
                'Contact tag must be a string.',
            );
        }

        $value = trim($value);

        if (
            $value === ''
            || strlen($value) > 80
            || preg_match('/[\x00-\x1F\x7F]/', $value) === 1
        ) {
            throw new InvalidArgumentException(
                'Contact tag is invalid.',
            );
        }

        return $value;
    }

    /**
     * @return list<int>
     */
    private static function listIds(
        mixed $value,
    ): array {
        if (!is_array($value) || !array_is_list($value)) {
            throw new InvalidArgumentException(
                'Contact identifiers must be a list.',
            );
        }

        if (count($value) > self::MAX_LISTS_PER_CONTACT) {
            throw new InvalidArgumentException(
                'Too many contact identifiers.',
            );
        }

        $result = [];

        foreach ($value as $id) {
            $id = self::positiveId($id);

            if ($id === null) {
                throw new InvalidArgumentException(
                    'Contact identifier list contains an invalid value.',
                );
            }

            $result[$id] = $id;
        }

        return array_values($result);
    }

    private static function listName(
        mixed $value,
    ): string {
        if (!is_string($value)) {
            throw new InvalidArgumentException(
                'Contact list name is required.',
            );
        }

        $value = trim($value);

        if (
            $value === ''
            || strlen($value) > 120
            || preg_match('/[\x00-\x1F\x7F]/', $value) === 1
        ) {
            throw new InvalidArgumentException(
                'Contact list name is invalid.',
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

    /**
     * @return array<string, mixed>
     */
    private static function decodeObject(
        mixed $value,
        string $label,
    ): array {
        if (is_array($value)) {
            return $value;
        }

        if (!is_string($value)) {
            throw new RuntimeException(
                sprintf('Invalid %s.', $label),
            );
        }

        $decoded = json_decode(
            $value,
            true,
            32,
            JSON_THROW_ON_ERROR,
        );

        if (
            !is_array($decoded)
            || ($decoded !== [] && array_is_list($decoded))
        ) {
            throw new RuntimeException(
                sprintf('Invalid %s.', $label),
            );
        }

        return $decoded;
    }

    /**
     * @return list<mixed>
     */
    private static function decodeList(
        mixed $value,
        string $label,
    ): array {
        if (is_array($value)) {
            $decoded = $value;
        } elseif (is_string($value)) {
            $decoded = json_decode(
                $value,
                true,
                32,
                JSON_THROW_ON_ERROR,
            );
        } else {
            throw new RuntimeException(
                sprintf('Invalid %s.', $label),
            );
        }

        if (!is_array($decoded) || !array_is_list($decoded)) {
            throw new RuntimeException(
                sprintf('Invalid %s.', $label),
            );
        }

        return $decoded;
    }

    private static function timestamp(
        mixed $value,
    ): string {
        if (!is_string($value)) {
            throw new RuntimeException(
                'Contact timestamp is invalid.',
            );
        }

        return (
            new DateTimeImmutable(
                $value,
                new DateTimeZone('UTC'),
            )
        )->format(DATE_ATOM);
    }

    private static function notFound(
        string $resource,
    ): JsonResponse {
        return self::error(
            $resource . '_not_found',
            ucfirst($resource) . ' was not found.',
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
