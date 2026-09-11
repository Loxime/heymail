<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Types\Types;
use Doctrine\Migrations\AbstractMigration;

final class Version20260911170000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Record the last sending-domain DNS ownership verification attempt.';
    }

    public function up(Schema $schema): void
    {
        $schema
            ->getTable('sending_domain')
            ->addColumn(
                'verification_checked_at',
                Types::DATETIME_IMMUTABLE,
                [
                    'notnull' => false,
                ],
            );
    }

    public function down(Schema $schema): void
    {
        $schema
            ->getTable('sending_domain')
            ->dropColumn(
                'verification_checked_at',
            );
    }
}
