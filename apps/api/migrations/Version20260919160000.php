<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260919160000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add workspace foundation and backfill existing console users.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
CREATE TABLE workspace (
    id BIGSERIAL NOT NULL,
    name VARCHAR(160) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CHECK (name <> '')
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE workspace_member (
    workspace_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    role VARCHAR(16) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (workspace_id, user_id),
    CONSTRAINT fk_workspace_member_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_workspace_member_user
        FOREIGN KEY (user_id)
        REFERENCES console_user (id)
        ON DELETE CASCADE,
    CHECK (role IN ('owner', 'admin', 'member'))
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_workspace_member_user ON workspace_member (user_id, workspace_id)'
        );

        /*
         * v1.1 has instance-level ownership only. Existing console users are
         * therefore attached to one shared legacy workspace. Mail-plane
         * ownership is deliberately NOT changed by this migration.
         */
        $this->addSql(
            <<<'SQL'
DO $$
DECLARE
    legacy_workspace_id BIGINT;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM console_user
    ) THEN
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

        INSERT INTO workspace_member (
            workspace_id,
            user_id,
            role,
            created_at
        )
        SELECT
            legacy_workspace_id,
            id,
            'owner',
            CURRENT_TIMESTAMP
        FROM console_user;
    END IF;
END
$$
SQL
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'DROP TABLE workspace_member'
        );

        $this->addSql(
            'DROP TABLE workspace'
        );
    }
}
