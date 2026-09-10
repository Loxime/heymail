<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260910223500 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Align outbound message payload unique index name with Doctrine metadata.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            'ALTER INDEX uniq_outbound_message_payload_message '
            . 'RENAME TO UNIQ_9DD6E69C8A59F918'
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'ALTER INDEX UNIQ_9DD6E69C8A59F918 '
            . 'RENAME TO uniq_outbound_message_payload_message'
        );
    }
}
