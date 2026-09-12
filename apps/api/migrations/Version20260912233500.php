<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260912233500 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Persist idempotent per-recipient SMTP delivery feedback.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
ALTER TABLE outbound_message_event
ADD recipient_hash VARCHAR(64) DEFAULT NULL,
ADD smtp_status VARCHAR(16) DEFAULT NULL,
ADD detail VARCHAR(1024) DEFAULT NULL,
ADD source_event_id VARCHAR(64) DEFAULT NULL
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_outbound_message_event_source
ON outbound_message_event (source_event_id)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_outbound_message_event_recipient
ON outbound_message_event (
    outbound_message_id,
    recipient_hash,
    occurred_at,
    id
)
SQL
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'DROP INDEX idx_outbound_message_event_recipient'
        );

        $this->addSql(
            'DROP INDEX uniq_outbound_message_event_source'
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE outbound_message_event
DROP recipient_hash,
DROP smtp_status,
DROP detail,
DROP source_event_id
SQL
        );
    }
}
