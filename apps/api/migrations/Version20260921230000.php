<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260921230000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add API-event automation triggers with idempotent ingress and dedicated quota.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
ALTER TABLE automation
ADD trigger_event_name VARCHAR(64) DEFAULT NULL
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE automation
DROP CONSTRAINT chk_automation_trigger
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE automation
ADD CONSTRAINT chk_automation_trigger
CHECK (
    trigger_type IN (
        'contact_added',
        'api_event'
    )
)
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE automation
ADD CONSTRAINT chk_automation_event_name
CHECK (
    (
        trigger_type = 'contact_added'
        AND trigger_event_name IS NULL
    )
    OR
    (
        trigger_type = 'api_event'
        AND trigger_event_name IS NOT NULL
        AND trigger_event_name
            ~ '^[a-z][a-z0-9_.-]{0,63}$'
    )
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_automation_api_event_trigger
ON automation (
    workspace_id,
    trigger_event_name,
    status,
    id
)
WHERE trigger_type = 'api_event'
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE automation_api_event (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    api_key_fingerprint VARCHAR(64) NOT NULL,
    idempotency_key_hash VARCHAR(64) NOT NULL,
    event_name VARCHAR(64) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    matched_automation_count INTEGER NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_automation_api_event_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT uniq_automation_api_event_idempotency
        UNIQUE (
            workspace_id,
            idempotency_key_hash
        ),
    CONSTRAINT chk_automation_api_event_fingerprint
        CHECK (
            api_key_fingerprint
                ~ '^[a-f0-9]{64}$'
        ),
    CONSTRAINT chk_automation_api_event_idempotency_hash
        CHECK (
            idempotency_key_hash
                ~ '^[a-f0-9]{64}$'
        ),
    CONSTRAINT chk_automation_api_event_request_hash
        CHECK (
            request_hash
                ~ '^[a-f0-9]{64}$'
        ),
    CONSTRAINT chk_automation_api_event_name
        CHECK (
            event_name
                ~ '^[a-z][a-z0-9_.-]{0,63}$'
        ),
    CONSTRAINT chk_automation_api_event_match_count
        CHECK (
            matched_automation_count >= 0
        )
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_automation_api_event_workspace
ON automation_api_event (
    workspace_id,
    id DESC
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE automation_api_event_quota_hour (
    api_key_fingerprint VARCHAR(64) NOT NULL,
    window_started_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    request_count INTEGER NOT NULL,
    PRIMARY KEY (
        api_key_fingerprint,
        window_started_at
    ),
    CONSTRAINT chk_automation_api_event_quota_fingerprint
        CHECK (
            api_key_fingerprint
                ~ '^[a-f0-9]{64}$'
        ),
    CONSTRAINT chk_automation_api_event_quota_count
        CHECK (
            request_count >= 1
        )
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
        FROM automation
        WHERE trigger_type = 'api_event'
    )
    OR EXISTS (
        SELECT 1
        FROM automation_api_event
    )
    OR EXISTS (
        SELECT 1
        FROM automation_api_event_quota_hour
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back API-event automations: API-event data would be lost.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'DROP TABLE automation_api_event_quota_hour'
        );

        $this->addSql(
            'DROP TABLE automation_api_event'
        );

        $this->addSql(
            'DROP INDEX idx_automation_api_event_trigger'
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE automation
DROP CONSTRAINT chk_automation_event_name
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE automation
DROP CONSTRAINT chk_automation_trigger
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE automation
ADD CONSTRAINT chk_automation_trigger
CHECK (
    trigger_type IN ('contact_added')
)
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE automation
DROP COLUMN trigger_event_name
SQL
        );
    }
}
