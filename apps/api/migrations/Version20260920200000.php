<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260920200000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add workspace email suppressions and durable campaign suppression skips.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
CREATE TABLE email_suppression (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    contact_list_id BIGINT DEFAULT NULL,
    email VARCHAR(254) NOT NULL,
    email_hash VARCHAR(64) NOT NULL,
    scope VARCHAR(16) NOT NULL,
    reason VARCHAR(32) NOT NULL,
    source_outbound_message_id BIGINT DEFAULT NULL,
    source_event_id VARCHAR(64) DEFAULT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_email_suppression_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_email_suppression_list
        FOREIGN KEY (contact_list_id)
        REFERENCES contact_list (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_email_suppression_outbound
        FOREIGN KEY (source_outbound_message_id)
        REFERENCES outbound_message (id)
        ON DELETE SET NULL,
    CONSTRAINT chk_email_suppression_scope
        CHECK (scope IN ('global', 'list')),
    CONSTRAINT chk_email_suppression_reason
        CHECK (reason IN ('manual', 'hard_bounce', 'unsubscribe')),
    CONSTRAINT chk_email_suppression_scope_list
        CHECK (
            (scope = 'global' AND contact_list_id IS NULL)
            OR
            (scope = 'list' AND contact_list_id IS NOT NULL)
        ),
    CONSTRAINT chk_email_suppression_hash
        CHECK (email_hash ~ '^[a-f0-9]{64}$'),
    CONSTRAINT chk_email_suppression_source_event
        CHECK (
            source_event_id IS NULL
            OR source_event_id ~ '^[a-f0-9]{64}$'
        )
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_email_suppression_global
ON email_suppression (
    workspace_id,
    email_hash
)
WHERE scope = 'global'
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_email_suppression_list
ON email_suppression (
    workspace_id,
    contact_list_id,
    email_hash
)
WHERE scope = 'list'
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_email_suppression_workspace ON email_suppression (workspace_id, id DESC)'
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE campaign_recipient_skip (
    campaign_id BIGINT NOT NULL,
    recipient_index INTEGER NOT NULL,
    suppression_id BIGINT DEFAULT NULL,
    reason VARCHAR(32) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (
        campaign_id,
        recipient_index
    ),
    CONSTRAINT fk_campaign_recipient_skip_campaign
        FOREIGN KEY (campaign_id)
        REFERENCES campaign (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_campaign_recipient_skip_suppression
        FOREIGN KEY (suppression_id)
        REFERENCES email_suppression (id)
        ON DELETE SET NULL,
    CONSTRAINT chk_campaign_recipient_skip_index
        CHECK (recipient_index >= 0),
    CONSTRAINT chk_campaign_recipient_skip_reason
        CHECK (reason IN ('manual', 'hard_bounce', 'unsubscribe'))
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_campaign_recipient_skip_suppression ON campaign_recipient_skip (suppression_id)'
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
        FROM campaign_recipient_skip
    )
    OR EXISTS (
        SELECT 1
        FROM email_suppression
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back suppressions: suppression data would be lost.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'DROP TABLE campaign_recipient_skip'
        );

        $this->addSql(
            'DROP TABLE email_suppression'
        );
    }
}
