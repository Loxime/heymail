<?php
declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260920180000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add workspace campaigns with encrypted immutable scheduling snapshots.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(<<<'SQL'
CREATE TABLE campaign (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    name VARCHAR(160) NOT NULL,
    sender_identity_id BIGINT DEFAULT NULL,
    template_id BIGINT DEFAULT NULL,
    source_list_id BIGINT DEFAULT NULL,
    status VARCHAR(24) NOT NULL,
    scheduled_for TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL,
    snapshot_at TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL,
    template_version INTEGER DEFAULT NULL,
    recipient_count INTEGER NOT NULL DEFAULT 0,
    snapshot_ciphertext TEXT DEFAULT NULL,
    snapshot_nonce VARCHAR(64) DEFAULT NULL,
    snapshot_wrapped_dek VARCHAR(128) DEFAULT NULL,
    snapshot_wrap_nonce VARCHAR(64) DEFAULT NULL,
    snapshot_algorithm VARCHAR(64) DEFAULT NULL,
    snapshot_key_version INTEGER DEFAULT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_campaign_workspace FOREIGN KEY (workspace_id)
        REFERENCES workspace (id) ON DELETE CASCADE,
    CONSTRAINT fk_campaign_sender FOREIGN KEY (sender_identity_id)
        REFERENCES sender_identity (id) ON DELETE SET NULL,
    CONSTRAINT fk_campaign_template FOREIGN KEY (template_id)
        REFERENCES email_template (id) ON DELETE SET NULL,
    CONSTRAINT fk_campaign_list FOREIGN KEY (source_list_id)
        REFERENCES contact_list (id) ON DELETE SET NULL,
    CONSTRAINT chk_campaign_status CHECK (
        status IN ('draft','scheduled','ready','cancelled')
    ),
    CONSTRAINT chk_campaign_recipient_count CHECK (recipient_count >= 0),
    CONSTRAINT chk_campaign_snapshot_shape CHECK (
        (
            snapshot_at IS NULL
            AND template_version IS NULL
            AND recipient_count = 0
            AND snapshot_ciphertext IS NULL
            AND snapshot_nonce IS NULL
            AND snapshot_wrapped_dek IS NULL
            AND snapshot_wrap_nonce IS NULL
            AND snapshot_algorithm IS NULL
            AND snapshot_key_version IS NULL
        ) OR (
            snapshot_at IS NOT NULL
            AND template_version IS NOT NULL
            AND template_version > 0
            AND recipient_count > 0
            AND snapshot_ciphertext IS NOT NULL
            AND snapshot_nonce IS NOT NULL
            AND snapshot_wrapped_dek IS NOT NULL
            AND snapshot_wrap_nonce IS NOT NULL
            AND snapshot_algorithm IS NOT NULL
            AND snapshot_key_version IS NOT NULL
        )
    )
)
SQL);
        $this->addSql('CREATE INDEX idx_campaign_workspace ON campaign (workspace_id, id DESC)');
        $this->addSql('CREATE INDEX idx_campaign_due ON campaign (status, scheduled_for, id)');
    }

    public function down(Schema $schema): void
    {
        $this->addSql(<<<'SQL'
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM campaign) THEN
        RAISE EXCEPTION 'Cannot roll back campaigns: campaign data would be lost.';
    END IF;
END
$$
SQL);
        $this->addSql('DROP TABLE campaign');
    }
}
