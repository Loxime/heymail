<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260920190000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add resumable campaign batch execution, delivery mapping, and workspace quota reservations.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            "ALTER TABLE campaign DROP CONSTRAINT chk_campaign_status"
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE campaign
ADD processed_count INTEGER NOT NULL DEFAULT 0,
ADD paused_at TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL,
ADD completed_at TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL,
ADD last_error VARCHAR(500) DEFAULT NULL,
ADD CONSTRAINT chk_campaign_processed_count
    CHECK (
        processed_count >= 0
        AND processed_count <= recipient_count
    ),
ADD CONSTRAINT chk_campaign_status
    CHECK (
        status IN (
            'draft',
            'scheduled',
            'ready',
            'processing',
            'paused',
            'completed',
            'cancelled'
        )
    )
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE campaign_delivery (
    campaign_id BIGINT NOT NULL,
    recipient_index INTEGER NOT NULL,
    outbound_message_id BIGINT NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (
        campaign_id,
        recipient_index
    ),
    CONSTRAINT fk_campaign_delivery_campaign
        FOREIGN KEY (campaign_id)
        REFERENCES campaign (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_campaign_delivery_outbound
        FOREIGN KEY (outbound_message_id)
        REFERENCES outbound_message (id)
        ON DELETE RESTRICT,
    CONSTRAINT chk_campaign_delivery_index
        CHECK (recipient_index >= 0),
    CONSTRAINT uniq_campaign_delivery_outbound
        UNIQUE (outbound_message_id)
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_campaign_delivery_message ON campaign_delivery (outbound_message_id)'
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE campaign_quota_reservation (
    workspace_id BIGINT NOT NULL,
    window_started_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    campaign_id BIGINT NOT NULL,
    recipient_index INTEGER NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (
        workspace_id,
        window_started_at,
        campaign_id,
        recipient_index
    ),
    CONSTRAINT fk_campaign_quota_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_campaign_quota_campaign
        FOREIGN KEY (campaign_id)
        REFERENCES campaign (id)
        ON DELETE CASCADE,
    CONSTRAINT chk_campaign_quota_index
        CHECK (recipient_index >= 0)
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_campaign_quota_window ON campaign_quota_reservation (workspace_id, window_started_at)'
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
        FROM campaign_delivery
    )
    OR EXISTS (
        SELECT 1
        FROM campaign_quota_reservation
    )
    OR EXISTS (
        SELECT 1
        FROM campaign
        WHERE processed_count <> 0
           OR paused_at IS NOT NULL
           OR completed_at IS NOT NULL
           OR last_error IS NOT NULL
           OR status IN ('processing', 'paused', 'completed')
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back campaign execution: execution data would be lost.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'DROP TABLE campaign_quota_reservation'
        );
        $this->addSql(
            'DROP TABLE campaign_delivery'
        );

        $this->addSql(
            "ALTER TABLE campaign DROP CONSTRAINT chk_campaign_status"
        );
        $this->addSql(
            "ALTER TABLE campaign DROP CONSTRAINT chk_campaign_processed_count"
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE campaign
DROP COLUMN processed_count,
DROP COLUMN paused_at,
DROP COLUMN completed_at,
DROP COLUMN last_error,
ADD CONSTRAINT chk_campaign_status
    CHECK (
        status IN (
            'draft',
            'scheduled',
            'ready',
            'cancelled'
        )
    )
SQL
        );
    }
}
