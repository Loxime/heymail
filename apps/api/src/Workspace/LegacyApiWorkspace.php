<?php

declare(strict_types=1);

namespace App\Workspace;

use Doctrine\DBAL\Connection;
use RuntimeException;

final class LegacyApiWorkspace
{
    private ?int $id = null;

    public function __construct(
        private readonly Connection $connection,
    ) {
    }

    public function id(): int
    {
        if ($this->id !== null) {
            return $this->id;
        }

        $ids = $this->connection->fetchFirstColumn(
            <<<'SQL'
SELECT id
FROM workspace
WHERE name = 'HeyMail Legacy Workspace'
ORDER BY id ASC
LIMIT 2
SQL
        );

        if (count($ids) !== 1) {
            throw new RuntimeException(
                'Expected exactly one HeyMail legacy API workspace.',
            );
        }

        $id = filter_var(
            $ids[0],
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        if (!is_int($id)) {
            throw new RuntimeException(
                'Legacy API workspace has an invalid identifier.',
            );
        }

        $this->id = $id;

        return $id;
    }

    public function owns(
        ?int $workspaceId,
    ): bool {
        return $workspaceId === null
            || $workspaceId === $this->id();
    }
}
