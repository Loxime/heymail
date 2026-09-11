<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Types\Types;
use Doctrine\Migrations\AbstractMigration;

final class Version20260911200000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create sender identities linked to verified sending domains.';
    }

    public function up(Schema $schema): void
    {
        $table =
            $schema
                ->createTable(
                    'sender_identity',
                );

        $table
            ->addColumn(
                'id',
                Types::BIGINT,
                [
                    'autoincrement' => true,
                    'notnull' => true,
                ],
            );

        $table
            ->addColumn(
                'sending_domain_id',
                Types::BIGINT,
                [
                    'notnull' => true,
                ],
            );

        $table
            ->addColumn(
                'email',
                Types::STRING,
                [
                    'length' => 254,
                    'notnull' => true,
                ],
            );

        $table
            ->addColumn(
                'created_at',
                Types::DATETIME_IMMUTABLE,
                [
                    'notnull' => true,
                ],
            );

        $table
            ->setPrimaryKey([
                'id',
            ]);

        $table
            ->addUniqueIndex(
                [
                    'email',
                ],
                'uniq_sender_identity_email',
            );

        $table
            ->addIndex(
                [
                    'sending_domain_id',
                ],
                'idx_sender_identity_domain',
            );

        $table
            ->addForeignKeyConstraint(
                'sending_domain',
                [
                    'sending_domain_id',
                ],
                [
                    'id',
                ],
                [
                    'onDelete' => 'RESTRICT',
                ],
                'fk_sender_identity_domain',
            );
    }

    public function down(Schema $schema): void
    {
        $schema
            ->dropTable(
                'sender_identity',
            );
    }
}
