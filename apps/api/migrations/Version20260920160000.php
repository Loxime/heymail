<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260920160000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add workspace-scoped versioned email templates';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(<<<'SQL'
CREATE TABLE email_template (
    id BIGSERIAL NOT NULL,
    workspace_id BIGINT NOT NULL,
    name VARCHAR(160) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY(id),
    CONSTRAINT fk_email_template_workspace
        FOREIGN KEY (workspace_id)
        REFERENCES workspace (id)
        ON DELETE CASCADE,
    CONSTRAINT chk_email_template_name
        CHECK (length(trim(name)) BETWEEN 1 AND 160)
)
SQL);

        $this->addSql(<<<'SQL'
CREATE UNIQUE INDEX uniq_email_template_workspace_name
ON email_template (workspace_id, lower(name))
SQL);

        $this->addSql(<<<'SQL'
CREATE INDEX idx_email_template_workspace_id
ON email_template (workspace_id, id)
SQL);

        $this->addSql(<<<'SQL'
CREATE TABLE email_template_version (
    id BIGSERIAL NOT NULL,
    template_id BIGINT NOT NULL,
    version INTEGER NOT NULL,
    subject VARCHAR(255) NOT NULL,
    text_body TEXT DEFAULT NULL,
    html_body TEXT DEFAULT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY(id),
    CONSTRAINT fk_email_template_version_template
        FOREIGN KEY (template_id)
        REFERENCES email_template (id)
        ON DELETE CASCADE,
    CONSTRAINT chk_email_template_version_number
        CHECK (version > 0),
    CONSTRAINT chk_email_template_version_subject
        CHECK (length(trim(subject)) BETWEEN 1 AND 255),
    CONSTRAINT chk_email_template_version_body
        CHECK (
            COALESCE(length(text_body), 0) > 0
            OR COALESCE(length(html_body), 0) > 0
        )
)
SQL);

        $this->addSql(<<<'SQL'
CREATE UNIQUE INDEX uniq_email_template_version_number
ON email_template_version (template_id, version)
SQL);

        $this->addSql(<<<'SQL'
CREATE INDEX idx_email_template_version_template_id
ON email_template_version (template_id, id DESC)
SQL);
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE email_template_version');
        $this->addSql('DROP TABLE email_template');
    }
}
