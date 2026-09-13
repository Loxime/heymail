<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260912235500 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add indexes for outbound message query API.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_outbound_message_status_list
ON outbound_message (
    status,
    id
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_outbound_message_created_list
ON outbound_message (
    created_at,
    id
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_outbound_message_event_type_message
ON outbound_message_event (
    event_type,
    outbound_message_id
)
SQL
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'DROP INDEX idx_outbound_message_event_type_message'
        );

        $this->addSql(
            'DROP INDEX idx_outbound_message_created_list'
        );

        $this->addSql(
            'DROP INDEX idx_outbound_message_status_list'
        );
    }
}
