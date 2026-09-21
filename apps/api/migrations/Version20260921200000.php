<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260921200000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add optional campaign open/click tracking with privacy-bounded events.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
ALTER TABLE campaign
ADD tracking_enabled BOOLEAN NOT NULL DEFAULT FALSE
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE campaign_tracking_event (
    id BIGSERIAL NOT NULL,
    campaign_id BIGINT NOT NULL,
    recipient_index INTEGER NOT NULL,
    event_type VARCHAR(16) NOT NULL,
    target_hash VARCHAR(64) DEFAULT NULL,
    occurred_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_campaign_tracking_campaign
        FOREIGN KEY (campaign_id)
        REFERENCES campaign (id)
        ON DELETE CASCADE,
    CONSTRAINT chk_campaign_tracking_index
        CHECK (recipient_index >= 0),
    CONSTRAINT chk_campaign_tracking_type
        CHECK (event_type IN ('opened', 'clicked')),
    CONSTRAINT chk_campaign_tracking_shape
        CHECK (
            (event_type = 'opened' AND target_hash IS NULL)
            OR
            (event_type = 'clicked' AND target_hash ~ '^[a-f0-9]{64}$')
        )
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_campaign_tracking_open
ON campaign_tracking_event (
    campaign_id,
    recipient_index,
    event_type
)
WHERE event_type = 'opened'
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_campaign_tracking_click
ON campaign_tracking_event (
    campaign_id,
    recipient_index,
    event_type,
    target_hash
)
WHERE event_type = 'clicked'
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_campaign_tracking_campaign_time
ON campaign_tracking_event (
    campaign_id,
    occurred_at
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
        FROM campaign_tracking_event
    )
    OR EXISTS (
        SELECT 1
        FROM campaign
        WHERE tracking_enabled = TRUE
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back campaign tracking: tracking configuration or events would be lost.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'DROP TABLE campaign_tracking_event'
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE campaign
DROP COLUMN tracking_enabled
SQL
        );
    }
}
