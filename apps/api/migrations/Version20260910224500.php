<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Types\Types;
use Doctrine\Migrations\AbstractMigration;

final class Version20260910224500 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Create the sending domain registry and DNS verification challenge.';
    }

    public function up(Schema $schema): void
    {
        $table = $schema->createTable(
            'sending_domain',
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
            'domain',
            Types::STRING,
            [
                'length' => 253,
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'status',
            Types::STRING,
            [
                'length' => 32,
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'verification_token',
            Types::STRING,
            [
                'length' => 64,
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'created_at',
            Types::DATETIME_IMMUTABLE,
            [
                'notnull' => true,
            ],
        );

        $table->addColumn(
            'verified_at',
            Types::DATETIME_IMMUTABLE,
            [
                'notnull' => false,
            ],
        );

        $table->addColumn(
            'disabled_at',
            Types::DATETIME_IMMUTABLE,
            [
                'notnull' => false,
            ],
        );

        $table->setPrimaryKey([
            'id',
        ]);

        $table->addUniqueIndex(
            [
                'domain',
            ],
            'uniq_sending_domain_domain',
        );

        $table->addUniqueIndex(
            [
                'verification_token',
            ],
            'uniq_sending_domain_verification_token',
        );
    }

    public function down(Schema $schema): void
    {
        $schema->dropTable(
            'sending_domain',
        );
    }
}
