<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Types\Types;
use Doctrine\Migrations\AbstractMigration;

final class Version20260911213000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Store public per-domain DKIM provisioning state.';
    }

    public function up(
        Schema $schema,
    ): void {
        $table =
            $schema->getTable(
                'sending_domain',
            );

        $table->addColumn(
            'dkim_selector',
            Types::STRING,
            [
                'length' => 63,
                'notnull' => false,
            ],
        );

        $table->addColumn(
            'dkim_public_key',
            Types::TEXT,
            [
                'notnull' => false,
            ],
        );

        $table->addColumn(
            'dkim_provisioned_at',
            Types::DATETIME_IMMUTABLE,
            [
                'notnull' => false,
            ],
        );
    }

    public function down(
        Schema $schema,
    ): void {
        $table =
            $schema->getTable(
                'sending_domain',
            );

        $table->dropColumn(
            'dkim_selector',
        );

        $table->dropColumn(
            'dkim_public_key',
        );

        $table->dropColumn(
            'dkim_provisioned_at',
        );
    }
}
