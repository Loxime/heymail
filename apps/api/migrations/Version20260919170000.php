<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260919170000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Expand workspace ownership columns and backfill existing mail-plane aggregates.';
    }

    public function up(Schema $schema): void
    {
        /*
         * Expand first: columns remain nullable in this migration so the
         * existing v1.1 write paths remain compatible during rolling
         * deployment. A following migration will enforce NOT NULL only after
         * every application write path assigns a workspace explicitly.
         */
        $this->addSql(
            <<<'SQL'
ALTER TABLE sending_domain
ADD workspace_id BIGINT DEFAULT NULL
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE outbound_message
ADD workspace_id BIGINT DEFAULT NULL
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE webhook_endpoint
ADD workspace_id BIGINT DEFAULT NULL
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_sending_domain_workspace
ON sending_domain (workspace_id, id)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_outbound_message_workspace
ON outbound_message (workspace_id, id)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_webhook_endpoint_workspace
ON webhook_endpoint (workspace_id, id)
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE sending_domain
ADD CONSTRAINT fk_sending_domain_workspace
FOREIGN KEY (workspace_id)
REFERENCES workspace (id)
ON DELETE RESTRICT
NOT DEFERRABLE
INITIALLY IMMEDIATE
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE outbound_message
ADD CONSTRAINT fk_outbound_message_workspace
FOREIGN KEY (workspace_id)
REFERENCES workspace (id)
ON DELETE RESTRICT
NOT DEFERRABLE
INITIALLY IMMEDIATE
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE webhook_endpoint
ADD CONSTRAINT fk_webhook_endpoint_workspace
FOREIGN KEY (workspace_id)
REFERENCES workspace (id)
ON DELETE RESTRICT
NOT DEFERRABLE
INITIALLY IMMEDIATE
SQL
        );

        /*
         * v1.1 has one global API/mail-plane namespace. Existing global
         * resources therefore belong to the reserved legacy workspace.
         *
         * Version20260919160000 creates that workspace when console users
         * already exist. Fresh installations may have no console user yet,
         * so create the reserved workspace here when it is absent.
         */
        $this->addSql(
            <<<'SQL'
DO $$
DECLARE
    legacy_workspace_id BIGINT;
BEGIN
    SELECT id
    INTO legacy_workspace_id
    FROM workspace
    WHERE name = 'HeyMail Legacy Workspace'
    ORDER BY id ASC
    LIMIT 1;

    IF legacy_workspace_id IS NULL THEN
        INSERT INTO workspace (
            name,
            created_at
        )
        VALUES (
            'HeyMail Legacy Workspace',
            CURRENT_TIMESTAMP
        )
        RETURNING id
        INTO legacy_workspace_id;
    END IF;

    UPDATE sending_domain
    SET workspace_id = legacy_workspace_id
    WHERE workspace_id IS NULL;

    UPDATE outbound_message
    SET workspace_id = legacy_workspace_id
    WHERE workspace_id IS NULL;

    UPDATE webhook_endpoint
    SET workspace_id = legacy_workspace_id
    WHERE workspace_id IS NULL;
END
$$
SQL
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'ALTER TABLE webhook_endpoint DROP CONSTRAINT fk_webhook_endpoint_workspace'
        );

        $this->addSql(
            'ALTER TABLE outbound_message DROP CONSTRAINT fk_outbound_message_workspace'
        );

        $this->addSql(
            'ALTER TABLE sending_domain DROP CONSTRAINT fk_sending_domain_workspace'
        );

        $this->addSql(
            'DROP INDEX idx_webhook_endpoint_workspace'
        );

        $this->addSql(
            'DROP INDEX idx_outbound_message_workspace'
        );

        $this->addSql(
            'DROP INDEX idx_sending_domain_workspace'
        );

        $this->addSql(
            'ALTER TABLE webhook_endpoint DROP COLUMN workspace_id'
        );

        $this->addSql(
            'ALTER TABLE outbound_message DROP COLUMN workspace_id'
        );

        $this->addSql(
            'ALTER TABLE sending_domain DROP COLUMN workspace_id'
        );

        /*
         * Only remove an unowned reserved workspace. If the previous
         * workspace-foundation migration attached users to it, it is retained.
         */
        $this->addSql(
            <<<'SQL'
DELETE FROM workspace w
WHERE w.name = 'HeyMail Legacy Workspace'
  AND NOT EXISTS (
      SELECT 1
      FROM workspace_member wm
      WHERE wm.workspace_id = w.id
  )
SQL
        );
    }
}
