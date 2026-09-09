<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Types\Types;
use Doctrine\Migrations\AbstractMigration;

final class Version20260909195000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Track successful submission to the internal HeyMail MTA';
    }

    public function up(Schema $schema): void
    {
        $table = $schema->getTable(
            'outbound_message',
        );

        $table->addColumn(
            'submitted_at',
            Types::DATETIME_IMMUTABLE,
            [
                'notnull' => false,
            ],
        );
    }

    public function down(Schema $schema): void
    {
        $schema
            ->getTable(
                'outbound_message',
            )
            ->dropColumn(
                'submitted_at',
            );
    }
}
