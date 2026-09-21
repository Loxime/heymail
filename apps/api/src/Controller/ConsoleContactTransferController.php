<?php

declare(strict_types=1);

namespace App\Controller;

use App\Automation\ContactAddedAutomationTrigger;
use App\Console\ConsoleAuthentication;
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

#[Route('/console')]
final readonly class ConsoleContactTransferController
{
    private const int MAX_IMPORT_BYTES = 2000000;
    private const int MAX_IMPORT_ROWS = 500;
    private const int MAX_EXPORT_ROWS = 5000;
    private const int MAX_TAGS = 50;
    private const int MAX_LISTS = 100;
    private const int MAX_CUSTOM_FIELDS = 50;
    private const int MAX_CUSTOM_FIELDS_BYTES = 16384;

    public function __construct(
        private ConsoleAuthentication $authentication,
        private Connection $connection,
        private ContactAddedAutomationTrigger $automationTrigger,
    ) {
    }

    #[Route(
        '/contact-tags',
        name: 'console_contact_tags',
        methods: ['GET'],
    )]
    public function tags(Request $request): JsonResponse
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
    COUNT(a.contact_id) AS contact_count
FROM contact_tag t
LEFT JOIN contact_tag_assignment a
    ON a.workspace_id = t.workspace_id
   AND a.tag_id = t.id
WHERE t.workspace_id = :workspace_id
GROUP BY
    t.id,
    t.name,
    t.created_at
ORDER BY lower(t.name), t.id
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
                ],
                $rows,
            ),
        ]);
    }

    #[Route(
        '/contacts/import',
        name: 'console_contacts_import',
        methods: ['POST'],
    )]
    public function import(Request $request): JsonResponse
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        $contentType = strtolower(
            trim(
                explode(
                    ';',
                    (string) $request->headers->get('Content-Type', ''),
                    2,
                )[0],
            ),
        );

        if (!in_array($contentType, ['text/csv', 'application/csv'], true)) {
            return self::error(
                'unsupported_media_type',
                'Content-Type must be text/csv.',
                Response::HTTP_UNSUPPORTED_MEDIA_TYPE,
            );
        }

        $raw = $request->getContent();

        if ($raw === '' || strlen($raw) > self::MAX_IMPORT_BYTES) {
            return self::error(
                'invalid_csv',
                'CSV import must contain between 1 and 2000000 bytes.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        if (str_contains($raw, "\0")) {
            return self::error(
                'invalid_csv',
                'CSV import contains an invalid NUL byte.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $rows = self::csvRows($raw);
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_csv',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $this->connection->beginTransaction();

        try {
            $created = 0;
            $updated = 0;
            $now = self::now()->format('Y-m-d H:i:s');

            foreach ($rows as $row) {
                $existingId = self::positiveId(
                    $this->connection->fetchOne(
                        <<<'SQL'
SELECT id
FROM contact
WHERE workspace_id = :workspace_id
  AND email = :email
FOR UPDATE
SQL,
                        [
                            'workspace_id' => $workspaceId,
                            'email' => $row['email'],
                        ],
                    ),
                );

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
ON CONFLICT (workspace_id, email)
DO UPDATE SET
    name = EXCLUDED.name,
    custom_fields = EXCLUDED.custom_fields,
    updated_at = EXCLUDED.updated_at
RETURNING id
SQL,
                        [
                            'workspace_id' => $workspaceId,
                            'email' => $row['email'],
                            'name' => $row['name'],
                            'custom_fields' => json_encode(
                                $row['customFields'],
                                JSON_THROW_ON_ERROR | JSON_FORCE_OBJECT,
                            ),
                            'created_at' => $now,
                            'updated_at' => $now,
                        ],
                    ),
                );

                if ($contactId === null) {
                    throw new RuntimeException(
                        'Imported contact identifier is invalid.',
                    );
                }

                if ($existingId === null) {
                    ++$created;
                } else {
                    ++$updated;
                }

                $this->replaceTags(
                    $workspaceId,
                    $contactId,
                    $row['tags'],
                    $now,
                );

                $this->replaceLists(
                    $workspaceId,
                    $contactId,
                    $row['lists'],
                    $now,
                );

                if ($existingId === null) {
                    $this->automationTrigger->enqueue(
                        $workspaceId,
                        $contactId,
                    );
                }
            }

            $this->connection->commit();
        } catch (InvalidArgumentException $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            return self::error(
                'invalid_csv',
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
            'rows' => count($rows),
            'created' => $created,
            'updated' => $updated,
        ]);
    }

    #[Route(
        '/contacts/export',
        name: 'console_contacts_export',
        methods: ['GET'],
    )]
    public function export(Request $request): Response
    {
        $workspaceId = $this->workspaceId($request);

        if ($workspaceId instanceof JsonResponse) {
            return $workspaceId;
        }

        try {
            [$where, $params] = self::filters(
                $request,
                $workspaceId,
            );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_query',
                $exception->getMessage(),
                Response::HTTP_BAD_REQUEST,
            );
        }

        $sql = sprintf(
            <<<'SQL'
SELECT
    c.email,
    c.name,
    c.custom_fields,
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
            SELECT json_agg(l.name ORDER BY lower(l.name), l.id)
            FROM contact_list_member m
            INNER JOIN contact_list l
                ON l.workspace_id = m.workspace_id
               AND l.id = m.list_id
            WHERE m.workspace_id = c.workspace_id
              AND m.contact_id = c.id
        ),
        '[]'::json
    ) AS lists
FROM contact c
WHERE %s
ORDER BY c.id
LIMIT %d
SQL,
            implode("\nAND ", $where),
            self::MAX_EXPORT_ROWS + 1,
        );

        $rows = $this->connection->fetchAllAssociative(
            $sql,
            $params,
        );

        if (count($rows) > self::MAX_EXPORT_ROWS) {
            return self::error(
                'export_too_large',
                'Export matches more than 5000 contacts; narrow the segment.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $stream = fopen('php://temp', 'w+');

        if ($stream === false) {
            throw new RuntimeException(
                'Unable to allocate CSV export buffer.',
            );
        }

        fputcsv(
            $stream,
            [
                'email',
                'name',
                'tags_json',
                'lists_json',
                'custom_fields_json',
            ],
            ',',
            '"',
            '',
        );

        foreach ($rows as $row) {
            fputcsv(
                $stream,
                [
                    self::csvSafeCell(
                        (string) $row['email'],
                    ),
                    self::csvSafeCell(
                        $row['name'] === null
                            ? ''
                            : (string) $row['name'],
                    ),
                    json_encode(
                        self::decodeList(
                            $row['tags'] ?? '[]',
                            'contact tags',
                        ),
                        JSON_THROW_ON_ERROR,
                    ),
                    json_encode(
                        self::decodeList(
                            $row['lists'] ?? '[]',
                            'contact lists',
                        ),
                        JSON_THROW_ON_ERROR,
                    ),
                    json_encode(
                        self::decodeObject(
                            $row['custom_fields'] ?? '{}',
                            'contact custom fields',
                        ),
                        JSON_THROW_ON_ERROR | JSON_FORCE_OBJECT,
                    ),
                ],
                ',',
                '"',
                '',
            );
        }

        rewind($stream);
        $csv = stream_get_contents($stream);
        fclose($stream);

        if (!is_string($csv)) {
            throw new RuntimeException(
                'Unable to read CSV export buffer.',
            );
        }

        $response = new Response($csv);
        $response->headers->set(
            'Content-Type',
            'text/csv; charset=UTF-8',
        );
        $response->headers->set(
            'Content-Disposition',
            'attachment; filename="heymail-contacts.csv"',
        );
        $response->headers->set(
            'Cache-Control',
            'no-store',
        );
        $response->headers->set(
            'X-Content-Type-Options',
            'nosniff',
        );

        return $response;
    }

    /**
     * @return array{
     *     0:list<string>,
     *     1:array<string, int|string>
     * }
     */
    private static function filters(
        Request $request,
        int $workspaceId,
    ): array {
        $query = $request->query->all();

        foreach (array_keys($query) as $key) {
            if (
                !is_string($key)
                || !in_array(
                    $key,
                    ['q', 'tag', 'list'],
                    true,
                )
            ) {
                throw new InvalidArgumentException(
                    'Unexpected contact export query parameter.',
                );
            }
        }

        foreach ($query as $value) {
            if (!is_string($value)) {
                throw new InvalidArgumentException(
                    'Contact export query parameters must be scalar strings.',
                );
            }
        }

        $where = [
            'c.workspace_id = :workspace_id',
        ];

        $params = [
            'workspace_id' => $workspaceId,
        ];

        if (isset($query['q'])) {
            $q = trim($query['q']);

            if ($q === '' || strlen($q) > 160) {
                throw new InvalidArgumentException(
                    'q must contain between 1 and 160 characters.',
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
            $tag = self::tagName($query['tag']);

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
            $listId = self::positiveId(
                $query['list'],
            );

            if ($listId === null) {
                throw new InvalidArgumentException(
                    'list must be a positive identifier.',
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

        return [$where, $params];
    }

    /**
     * @return list<array{
     *     email:string,
     *     name:string|null,
     *     tags:list<string>,
     *     lists:list<string>,
     *     customFields:array<string, scalar|null>
     * }>
     */
    private static function csvRows(
        string $raw,
    ): array {
        $stream = fopen('php://temp', 'w+');

        if ($stream === false) {
            throw new RuntimeException(
                'Unable to allocate CSV import buffer.',
            );
        }

        fwrite($stream, $raw);
        rewind($stream);

        $header = fgetcsv($stream, null, ',', '"', '');

        if (!is_array($header)) {
            fclose($stream);
            throw new InvalidArgumentException(
                'CSV header is required.',
            );
        }

        if (isset($header[0]) && is_string($header[0])) {
            $header[0] = preg_replace(
                '/^\xEF\xBB\xBF/',
                '',
                $header[0],
            );
        }

        if (
            $header !== [
                'email',
                'name',
                'tags_json',
                'lists_json',
                'custom_fields_json',
            ]
        ) {
            fclose($stream);
            throw new InvalidArgumentException(
                'CSV header must be email,name,tags_json,lists_json,custom_fields_json.',
            );
        }

        $rows = [];
        $seen = [];
        $line = 1;

        while (($values = fgetcsv($stream, null, ',', '"', '')) !== false) {
            ++$line;

            if (
                count($values) === 1
                && ($values[0] === null || trim((string) $values[0]) === '')
            ) {
                continue;
            }

            if (count($values) !== 5) {
                fclose($stream);
                throw new InvalidArgumentException(
                    sprintf(
                        'CSV line %d must contain exactly 5 columns.',
                        $line,
                    ),
                );
            }

            if (count($rows) >= self::MAX_IMPORT_ROWS) {
                fclose($stream);
                throw new InvalidArgumentException(
                    'CSV import is limited to 500 contacts.',
                );
            }

            try {
                $email = self::email(
                    self::csvRestoreCell(
                        (string) $values[0],
                    ),
                );

                $name = self::contactName(
                    self::csvRestoreCell(
                        (string) $values[1],
                    ),
                );

                $tags = self::stringListJson(
                    (string) $values[2],
                    'tags_json',
                    self::MAX_TAGS,
                    80,
                );

                $lists = self::stringListJson(
                    (string) $values[3],
                    'lists_json',
                    self::MAX_LISTS,
                    120,
                );

                $customFields = self::customFieldsJson(
                    (string) $values[4],
                );
            } catch (InvalidArgumentException $exception) {
                fclose($stream);
                throw new InvalidArgumentException(
                    sprintf(
                        'CSV line %d: %s',
                        $line,
                        $exception->getMessage(),
                    ),
                );
            }

            if (isset($seen[$email])) {
                fclose($stream);
                throw new InvalidArgumentException(
                    sprintf(
                        'CSV line %d duplicates email %s.',
                        $line,
                        $email,
                    ),
                );
            }

            $seen[$email] = true;

            $rows[] = [
                'email' => $email,
                'name' => $name,
                'tags' => $tags,
                'lists' => $lists,
                'customFields' => $customFields,
            ];
        }

        fclose($stream);

        if ($rows === []) {
            throw new InvalidArgumentException(
                'CSV import contains no contacts.',
            );
        }

        return $rows;
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
                    'Unable to resolve imported contact tag.',
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
     * @param list<string> $listNames
     */
    private function replaceLists(
        int $workspaceId,
        int $contactId,
        array $listNames,
        string $now,
    ): void {
        $listIds = [];

        foreach ($listNames as $name) {
            $listId = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
SELECT id
FROM contact_list
WHERE workspace_id = :workspace_id
  AND lower(name) = lower(:name)
SQL,
                    [
                        'workspace_id' => $workspaceId,
                        'name' => $name,
                    ],
                ),
            );

            if ($listId === null) {
                throw new InvalidArgumentException(
                    sprintf(
                        'Unknown contact list "%s".',
                        $name,
                    ),
                );
            }

            $listIds[] = $listId;
        }

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

    private static function csvSafeCell(
        string $value,
    ): string {
        if (str_starts_with($value, "'")) {
            return "'" . $value;
        }

        if (
            $value !== ''
            && in_array(
                $value[0],
                ['=', '+', '-', '@'],
                true,
            )
        ) {
            return "'" . $value;
        }

        return $value;
    }

    private static function csvRestoreCell(
        string $value,
    ): string {
        if (str_starts_with($value, "''")) {
            return substr($value, 1);
        }

        if (
            strlen($value) >= 2
            && $value[0] === "'"
            && in_array(
                $value[1],
                ['=', '+', '-', '@'],
                true,
            )
        ) {
            return substr($value, 1);
        }

        return $value;
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
                'Contact name must be a string.',
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
     * @return list<string>
     */
    private static function stringListJson(
        string $raw,
        string $label,
        int $maxItems,
        int $maxLength,
    ): array {
        if (trim($raw) === '') {
            return [];
        }

        try {
            $decoded = json_decode(
                $raw,
                true,
                32,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException) {
            throw new InvalidArgumentException(
                sprintf('%s must contain valid JSON.', $label),
            );
        }

        if (!is_array($decoded) || !array_is_list($decoded)) {
            throw new InvalidArgumentException(
                sprintf('%s must be a JSON array.', $label),
            );
        }

        if (count($decoded) > $maxItems) {
            throw new InvalidArgumentException(
                sprintf('%s contains too many values.', $label),
            );
        }

        $result = [];
        $seen = [];

        foreach ($decoded as $value) {
            if (!is_string($value)) {
                throw new InvalidArgumentException(
                    sprintf('%s values must be strings.', $label),
                );
            }

            $value = trim($value);

            if (
                $value === ''
                || strlen($value) > $maxLength
                || preg_match('/[\x00-\x1F\x7F]/', $value) === 1
            ) {
                throw new InvalidArgumentException(
                    sprintf('%s contains an invalid value.', $label),
                );
            }

            $normalized = strtolower($value);

            if (isset($seen[$normalized])) {
                continue;
            }

            $seen[$normalized] = true;
            $result[] = $value;
        }

        return $result;
    }

    /**
     * @return array<string, scalar|null>
     */
    private static function customFieldsJson(
        string $raw,
    ): array {
        if (trim($raw) === '') {
            return [];
        }

        try {
            $decoded = json_decode(
                $raw,
                true,
                32,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException) {
            throw new InvalidArgumentException(
                'custom_fields_json must contain valid JSON.',
            );
        }

        if (
            !is_array($decoded)
            || ($decoded !== [] && array_is_list($decoded))
        ) {
            throw new InvalidArgumentException(
                'custom_fields_json must be a JSON object.',
            );
        }

        if (count($decoded) > self::MAX_CUSTOM_FIELDS) {
            throw new InvalidArgumentException(
                'custom_fields_json contains too many fields.',
            );
        }

        foreach ($decoded as $key => $value) {
            if (
                !is_string($key)
                || preg_match(
                    '/^[a-z][a-z0-9_]{0,63}$/D',
                    $key,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'custom_fields_json contains an invalid field name.',
                );
            }

            if (
                !is_string($value)
                && !is_int($value)
                && !is_float($value)
                && !is_bool($value)
                && $value !== null
            ) {
                throw new InvalidArgumentException(
                    'custom_fields_json values must be scalar or null.',
                );
            }

            if (
                is_string($value)
                && strlen($value) > 4096
            ) {
                throw new InvalidArgumentException(
                    'custom_fields_json contains a value that is too long.',
                );
            }
        }

        $encoded = json_encode(
            $decoded,
            JSON_THROW_ON_ERROR,
        );

        if (strlen($encoded) > self::MAX_CUSTOM_FIELDS_BYTES) {
            throw new InvalidArgumentException(
                'custom_fields_json is too large.',
            );
        }

        return $decoded;
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
