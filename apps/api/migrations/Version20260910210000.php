<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260910210000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Record outbound SMTP submission transition timestamps.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            'ALTER TABLE outbound_message '
            . 'ADD submitting_at '
            . 'TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL'
        );

        $this->addSql(
            'ALTER TABLE outbound_message '
            . 'ADD submission_uncertain_at '
            . 'TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL'
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'ALTER TABLE outbound_message '
            . 'DROP submitting_at'
        );

        $this->addSql(
            'ALTER TABLE outbound_message '
            . 'DROP submission_uncertain_at'
        );
    }
}
