<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Types\Types;
use Doctrine\Migrations\AbstractMigration;

final class Version20260906171000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create outbound message orchestration metadata';
    }

    public function up(Schema $schema): void
    {
        $table = $schema->createTable('outbound_message');

        $table->addColumn('id', Types::BIGINT, [
            'autoincrement' => true,
            'notnull' => true,
        ]);

        $table->addColumn(
            'idempotency_key_hash',
            Types::STRING,
            [
                'length' => 64,
                'notnull' => true,
            ],
        );

        $table->addColumn('status', Types::STRING, [
            'length' => 32,
            'notnull' => true,
        ]);

        $table->addColumn(
            'created_at',
            Types::DATETIME_IMMUTABLE,
            [
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'ready_for_submission_at',
            Types::DATETIME_IMMUTABLE,
            [
                'notnull' => false,
            ],
        );

        $table->setPrimaryKey(['id']);

        $table->addUniqueIndex(
            ['idempotency_key_hash'],
            'uniq_outbound_message_idempotency_hash',
        );
    }

    public function down(Schema $schema): void
    {
        $schema->dropTable('outbound_message');
    }
}
