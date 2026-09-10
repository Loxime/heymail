<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Types\Types;
use Doctrine\Migrations\AbstractMigration;

final class Version20260906160500 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create the Symfony Messenger transport table';
    }

    public function up(Schema $schema): void
    {
        $table = $schema->createTable('messenger_messages');

        $table->addColumn('id', Types::BIGINT, [
            'autoincrement' => true,
            'notnull' => true,
        ]);

        $table->addColumn('body', Types::TEXT, [
            'notnull' => true,
        ]);

        $table->addColumn('headers', Types::TEXT, [
            'notnull' => true,
        ]);

        $table->addColumn('queue_name', Types::STRING, [
            'length' => 190,
            'notnull' => true,
        ]);

        $table->addColumn('created_at', Types::DATETIME_IMMUTABLE, [
            'notnull' => true,
        ]);

        $table->addColumn('available_at', Types::DATETIME_IMMUTABLE, [
            'notnull' => true,
        ]);

        $table->addColumn('delivered_at', Types::DATETIME_IMMUTABLE, [
            'notnull' => false,
        ]);

        $table->setPrimaryKey(['id']);

        $table->addIndex(
            [
                'queue_name',
                'available_at',
                'delivered_at',
                'id',
            ],
            'idx_messenger_queue'
        );
    }

    public function down(Schema $schema): void
    {
        $schema->dropTable('messenger_messages');
    }
}
