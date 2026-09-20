<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260920170000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add workspace-scoped contacts, tags, and contact lists with favorite backfill.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
DO $$
BEGIN
    IF EXISTS (
        SELECT f.id
        FROM console_favorite_contact f
        LEFT JOIN workspace_member wm
            ON wm.user_id = f.user_id
        GROUP BY f.id
        HAVING COUNT(wm.workspace_id) <> 1
    ) THEN
        RAISE EXCEPTION
            'Cannot backfill contacts: every favorite owner must belong to exactly one workspace.';
    END IF;

    IF EXISTS (
        SELECT wm.workspace_id, lower(f.email)
        FROM console_favorite_contact f
        INNER JOIN workspace_member wm
            ON wm.user_id = f.user_id
        GROUP BY wm.workspace_id, lower(f.email)
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION
            'Cannot backfill contacts: duplicate favorite emails exist inside a workspace.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE contact (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    legacy_favorite_id BIGINT DEFAULT NULL,
    email VARCHAR(254) NOT NULL,
    name VARCHAR(160) DEFAULT NULL,
    custom_fields JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uniq_contact_workspace_id
        UNIQUE (workspace_id, id),
    CONSTRAINT uniq_contact_workspace_email
        UNIQUE (workspace_id, email),
    CONSTRAINT uniq_contact_legacy_favorite
        UNIQUE (legacy_favorite_id),
    CONSTRAINT fk_contact_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT fk_contact_legacy_favorite
        FOREIGN KEY (legacy_favorite_id)
        REFERENCES console_favorite_contact (id)
        ON DELETE SET NULL,
    CONSTRAINT chk_contact_custom_fields_object
        CHECK (jsonb_typeof(custom_fields) = 'object')
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_contact_workspace_id ON contact (workspace_id, id DESC)'
        );

        $this->addSql(
            'CREATE INDEX idx_contact_workspace_email_search ON contact (workspace_id, lower(email))'
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE contact_tag (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    name VARCHAR(80) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uniq_contact_tag_workspace_id
        UNIQUE (workspace_id, id),
    CONSTRAINT fk_contact_tag_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_contact_tag_workspace_name
ON contact_tag (
    workspace_id,
    lower(name)
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE contact_tag_assignment (
    workspace_id BIGINT NOT NULL,
    contact_id BIGINT NOT NULL,
    tag_id BIGINT NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (workspace_id, contact_id, tag_id),
    CONSTRAINT fk_contact_tag_assignment_contact
        FOREIGN KEY (workspace_id, contact_id)
        REFERENCES contact (workspace_id, id)
        ON DELETE CASCADE,
    CONSTRAINT fk_contact_tag_assignment_tag
        FOREIGN KEY (workspace_id, tag_id)
        REFERENCES contact_tag (workspace_id, id)
        ON DELETE CASCADE
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE contact_list (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    name VARCHAR(120) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uniq_contact_list_workspace_id
        UNIQUE (workspace_id, id),
    CONSTRAINT fk_contact_list_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE UNIQUE INDEX uniq_contact_list_workspace_name
ON contact_list (
    workspace_id,
    lower(name)
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE contact_list_member (
    workspace_id BIGINT NOT NULL,
    list_id BIGINT NOT NULL,
    contact_id BIGINT NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (workspace_id, list_id, contact_id),
    CONSTRAINT fk_contact_list_member_list
        FOREIGN KEY (workspace_id, list_id)
        REFERENCES contact_list (workspace_id, id)
        ON DELETE CASCADE,
    CONSTRAINT fk_contact_list_member_contact
        FOREIGN KEY (workspace_id, contact_id)
        REFERENCES contact (workspace_id, id)
        ON DELETE CASCADE
)
SQL
        );

        $this->addSql(
            <<<'SQL'
INSERT INTO contact (
    workspace_id,
    legacy_favorite_id,
    email,
    name,
    custom_fields,
    created_at,
    updated_at
)
SELECT
    wm.workspace_id,
    f.id,
    lower(f.email),
    f.name,
    '{}'::jsonb,
    f.created_at,
    f.created_at
FROM console_favorite_contact f
INNER JOIN workspace_member wm
    ON wm.user_id = f.user_id
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
        FROM contact_tag
    ) OR EXISTS (
        SELECT 1
        FROM contact_list
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back contacts: tags or lists would be lost.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM contact c
        WHERE c.legacy_favorite_id IS NULL
           OR c.custom_fields <> '{}'::jsonb
           OR NOT EXISTS (
               SELECT 1
               FROM console_favorite_contact f
               WHERE f.id = c.legacy_favorite_id
                 AND lower(f.email) = lower(c.email)
                 AND f.name IS NOT DISTINCT FROM c.name
           )
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back contacts: workspace contact data would be lost.';
    END IF;
END
$$
SQL
        );

        $this->addSql('DROP TABLE contact_list_member');
        $this->addSql('DROP TABLE contact_list');
        $this->addSql('DROP TABLE contact_tag_assignment');
        $this->addSql('DROP TABLE contact_tag');
        $this->addSql('DROP TABLE contact');
    }
}
