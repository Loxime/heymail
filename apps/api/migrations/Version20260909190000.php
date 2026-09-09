<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Types\Types;
use Doctrine\Migrations\AbstractMigration;

final class Version20260909190000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Store encrypted outbound email payloads';
    }

    public function up(Schema $schema): void
    {
        $table = $schema->createTable(
            'outbound_message_payload',
        );

        $table->addColumn(
            'id',
            Types::BIGINT,
            [
                'autoincrement' => true,
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'outbound_message_id',
            Types::BIGINT,
            [
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'ciphertext',
            Types::TEXT,
            [
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'nonce',
            Types::STRING,
            [
                'length' => 64,
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'wrapped_dek',
            Types::STRING,
            [
                'length' => 128,
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'wrap_nonce',
            Types::STRING,
            [
                'length' => 64,
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'algorithm',
            Types::STRING,
            [
                'length' => 64,
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'key_version',
            Types::SMALLINT,
            [
                'notnull' => true,
            ],
        );

        $table->setPrimaryKey([
            'id',
        ]);

        $table->addUniqueIndex(
            [
                'outbound_message_id',
            ],
            'uniq_outbound_message_payload_message',
        );

        $table->addForeignKeyConstraint(
            'outbound_message',
            [
                'outbound_message_id',
            ],
            [
                'id',
            ],
            [
                'onDelete' => 'CASCADE',
            ],
            'fk_outbound_message_payload_message',
        );
    }

    public function down(Schema $schema): void
    {
        $schema->dropTable(
            'outbound_message_payload',
        );
    }
}
