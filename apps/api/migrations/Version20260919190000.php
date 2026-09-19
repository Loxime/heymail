<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260919190000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add workspace API credentials and scope outbound idempotency by workspace.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
CREATE TABLE api_credential (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    api_key VARCHAR(35) NOT NULL,
    key_fingerprint VARCHAR(64) NOT NULL,
    secret_hash VARCHAR(255) NOT NULL,
    label VARCHAR(100) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    last_used_at TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL,
    revoked_at TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_api_credential_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT uniq_api_credential_key
        UNIQUE (api_key),
    CONSTRAINT uniq_api_credential_fingerprint
        UNIQUE (key_fingerprint),
    CHECK (api_key ~ '^hm_[a-f0-9]{32}$'),
    CHECK (key_fingerprint ~ '^[a-f0-9]{64}$'),
    CHECK (secret_hash <> ''),
    CHECK (label <> '')
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_api_credential_workspace ON api_credential (workspace_id, id)'
        );

        $this->addSql(
            'DROP INDEX uniq_outbound_message_idempotency_hash'
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_outbound_message_workspace_idempotency_hash
ON outbound_message (
    workspace_id,
    idempotency_key_hash
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
        FROM outbound_message
        GROUP BY idempotency_key_hash
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION
            'Cannot restore global idempotency uniqueness while cross-workspace duplicate hashes exist.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'DROP INDEX uniq_outbound_message_workspace_idempotency_hash'
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_outbound_message_idempotency_hash
ON outbound_message (
    idempotency_key_hash
)
SQL
        );

        $this->addSql(
            'DROP TABLE api_credential'
        );
    }
}
