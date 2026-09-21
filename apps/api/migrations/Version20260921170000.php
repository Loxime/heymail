<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260921170000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Persist privacy-bounded recipient domains for delivery statistics.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
ALTER TABLE outbound_message_event
ADD recipient_domain VARCHAR(253) DEFAULT NULL
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE outbound_message_event
ADD CONSTRAINT chk_outbound_message_event_recipient_domain
CHECK (
    recipient_domain IS NULL
    OR (
        char_length(recipient_domain) BETWEEN 1 AND 253
        AND recipient_domain = lower(recipient_domain)
        AND recipient_domain ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
    )
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_outbound_message_event_domain_activity
ON outbound_message_event (
    occurred_at,
    event_type,
    recipient_domain
)
SQL
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM outbound_message_event
        WHERE recipient_domain IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back recipient-domain statistics: populated analytics data would be lost.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'DROP INDEX idx_outbound_message_event_domain_activity'
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE outbound_message_event
DROP CONSTRAINT chk_outbound_message_event_recipient_domain
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE outbound_message_event
DROP COLUMN recipient_domain
SQL
        );
    }
}
