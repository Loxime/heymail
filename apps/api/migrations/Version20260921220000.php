<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260921220000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add contact-added automation definitions, encrypted jobs, and quota reservations.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
CREATE TABLE automation (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    name VARCHAR(160) NOT NULL,
    trigger_type VARCHAR(32) NOT NULL,
    delay_seconds INTEGER NOT NULL,
    sender_identity_id BIGINT DEFAULT NULL,
    template_id BIGINT DEFAULT NULL,
    status VARCHAR(16) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_automation_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_automation_sender
        FOREIGN KEY (sender_identity_id)
        REFERENCES sender_identity (id)
        ON DELETE SET NULL,
    CONSTRAINT fk_automation_template
        FOREIGN KEY (template_id)
        REFERENCES email_template (id)
        ON DELETE SET NULL,
    CONSTRAINT chk_automation_trigger
        CHECK (trigger_type IN ('contact_added')),
    CONSTRAINT chk_automation_delay
        CHECK (
            delay_seconds >= 0
            AND delay_seconds <= 31536000
        ),
    CONSTRAINT chk_automation_status
        CHECK (status IN ('active', 'paused'))
)
SQL
        );

        $this->addSql(
            'CREATE UNIQUE INDEX uniq_automation_workspace_name '
            . 'ON automation (workspace_id, lower(name))'
        );

        $this->addSql(
            'CREATE INDEX idx_automation_trigger '
            . 'ON automation (workspace_id, trigger_type, status, id)'
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE automation_job (
    id BIGSERIAL NOT NULL,
    automation_id BIGINT NOT NULL,
    workspace_id BIGINT NOT NULL,
    trigger_key VARCHAR(128) NOT NULL,
    status VARCHAR(16) NOT NULL,
    due_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    snapshot_at TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL,
    snapshot_ciphertext TEXT DEFAULT NULL,
    snapshot_nonce VARCHAR(64) DEFAULT NULL,
    snapshot_wrapped_dek VARCHAR(128) DEFAULT NULL,
    snapshot_wrap_nonce VARCHAR(64) DEFAULT NULL,
    snapshot_algorithm VARCHAR(64) DEFAULT NULL,
    snapshot_key_version INTEGER DEFAULT NULL,
    outbound_message_id BIGINT DEFAULT NULL,
    skip_reason VARCHAR(64) DEFAULT NULL,
    last_error VARCHAR(500) DEFAULT NULL,
    completed_at TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_automation_job_automation
        FOREIGN KEY (automation_id)
        REFERENCES automation (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_automation_job_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_automation_job_outbound
        FOREIGN KEY (outbound_message_id)
        REFERENCES outbound_message (id)
        ON DELETE RESTRICT,
    CONSTRAINT uniq_automation_job_trigger
        UNIQUE (automation_id, trigger_key),
    CONSTRAINT chk_automation_job_status
        CHECK (
            status IN (
                'pending',
                'dispatching',
                'completed',
                'skipped'
            )
        ),
    CONSTRAINT chk_automation_job_snapshot
        CHECK (
            (
                snapshot_at IS NULL
                AND snapshot_ciphertext IS NULL
                AND snapshot_nonce IS NULL
                AND snapshot_wrapped_dek IS NULL
                AND snapshot_wrap_nonce IS NULL
                AND snapshot_algorithm IS NULL
                AND snapshot_key_version IS NULL
            )
            OR
            (
                snapshot_at IS NOT NULL
                AND snapshot_ciphertext IS NOT NULL
                AND snapshot_nonce IS NOT NULL
                AND snapshot_wrapped_dek IS NOT NULL
                AND snapshot_wrap_nonce IS NOT NULL
                AND snapshot_algorithm IS NOT NULL
                AND snapshot_key_version IS NOT NULL
            )
        ),
    CONSTRAINT chk_automation_job_pending_snapshot
        CHECK (
            status = 'skipped'
            OR snapshot_ciphertext IS NOT NULL
        ),
    CONSTRAINT chk_automation_job_outcome
        CHECK (
            (
                status IN ('pending', 'dispatching')
                AND outbound_message_id IS NULL
                AND skip_reason IS NULL
                AND completed_at IS NULL
            )
            OR
            (
                status = 'completed'
                AND outbound_message_id IS NOT NULL
                AND skip_reason IS NULL
                AND completed_at IS NOT NULL
            )
            OR
            (
                status = 'skipped'
                AND outbound_message_id IS NULL
                AND skip_reason IS NOT NULL
                AND completed_at IS NOT NULL
            )
        )
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_automation_job_due '
            . 'ON automation_job (status, due_at, id)'
        );

        $this->addSql(
            'CREATE INDEX idx_automation_job_workspace '
            . 'ON automation_job (workspace_id, id DESC)'
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE automation_quota_reservation (
    workspace_id BIGINT NOT NULL,
    window_started_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    automation_job_id BIGINT NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (
        workspace_id,
        window_started_at,
        automation_job_id
    ),
    CONSTRAINT fk_automation_quota_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_automation_quota_job
        FOREIGN KEY (automation_job_id)
        REFERENCES automation_job (id)
        ON DELETE CASCADE
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_automation_quota_window '
            . 'ON automation_quota_reservation '
            . '(workspace_id, window_started_at)'
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
    )
    OR EXISTS (
        SELECT 1
        FROM automation_job
    )
    OR EXISTS (
        SELECT 1
        FROM automation_quota_reservation
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back automations: automation data would be lost.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'DROP TABLE automation_quota_reservation'
        );
        $this->addSql(
            'DROP TABLE automation_job'
        );
        $this->addSql(
            'DROP TABLE automation'
        );
    }
}
