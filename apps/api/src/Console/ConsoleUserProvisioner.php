<?php

declare(strict_types=1);

namespace App\Console;

use DateTimeImmutable;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use RuntimeException;
use Throwable;

final readonly class ConsoleUserProvisioner
{
    public function __construct(
        private Connection $connection,
    ) {
    }

    public function create(
        string $email,
        string $firstName,
        string $lastName,
        string $passwordHash,
        DateTimeImmutable $now,
    ): int {
        if (
            $email === ''
            || $firstName === ''
            || $lastName === ''
            || $passwordHash === ''
        ) {
            throw new InvalidArgumentException(
                'Invalid console user provisioning input.',
            );
        }

        $this->connection->beginTransaction();

        try {
            $userId = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
INSERT INTO console_user (
    email,
    first_name,
    last_name,
    password_hash,
    created_at,
    updated_at
)
VALUES (
    :email,
    :first_name,
    :last_name,
    :password_hash,
    :created_at,
    :updated_at
)
RETURNING id
SQL,
                    [
                        'email' => $email,
                        'first_name' => $firstName,
                        'last_name' => $lastName,
                        'password_hash' => $passwordHash,
                        'created_at' => $now->format('Y-m-d H:i:s'),
                        'updated_at' => $now->format('Y-m-d H:i:s'),
                    ],
                ),
            );

            $workspaceId = self::positiveId(
                $this->connection->fetchOne(
                    <<<'SQL'
INSERT INTO workspace (
    name,
    created_at
)
VALUES (
    :name,
    :created_at
)
RETURNING id
SQL,
                    [
                        'name' => sprintf(
                            '%s workspace',
                            $firstName,
                        ),
                        'created_at' => $now->format('Y-m-d H:i:s'),
                    ],
                ),
            );

            $this->connection->insert(
                'workspace_member',
                [
                    'workspace_id' => $workspaceId,
                    'user_id' => $userId,
                    'role' => 'owner',
                    'created_at' => $now->format('Y-m-d H:i:s'),
                ],
            );

            $this->connection->commit();

            return $userId;
        } catch (Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }
    }

    public function delete(
        int $userId,
    ): void {
        if ($userId < 1) {
            throw new InvalidArgumentException(
                'Invalid console user identifier.',
            );
        }

        $this->connection->beginTransaction();

        try {
            $workspaceIds =
                $this->connection
                    ->fetchFirstColumn(
                        <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
SQL,
                        [
                            'user_id' => $userId,
                        ],
                    );

            $this->connection->delete(
                'console_user',
                [
                    'id' => $userId,
                ],
            );

            foreach ($workspaceIds as $workspaceId) {
                $id = self::positiveId(
                    $workspaceId,
                );

                $this->connection
                    ->executeStatement(
                        <<<'SQL'
DELETE FROM workspace
WHERE id = :workspace_id
  AND NOT EXISTS (
      SELECT 1
      FROM workspace_member
      WHERE workspace_id = :workspace_id
  )
SQL,
                        [
                            'workspace_id' => $id,
                        ],
                    );
            }

            $this->connection->commit();
        } catch (Throwable $exception) {
            if ($this->connection->isTransactionActive()) {
                $this->connection->rollBack();
            }

            throw $exception;
        }
    }

    private static function positiveId(
        mixed $value,
    ): int {
        $id = filter_var(
            $value,
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        if (!is_int($id)) {
            throw new RuntimeException(
                'Database did not return a valid identifier.',
            );
        }

        return $id;
    }
}
