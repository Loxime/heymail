<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260921210000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Persist optional visual email documents on template versions.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
ALTER TABLE email_template_version
ADD visual_document JSONB DEFAULT NULL
SQL
        );

        $this->addSql(
            <<<'SQL'
ALTER TABLE email_template_version
ADD CONSTRAINT chk_email_template_version_visual_document
CHECK (
    visual_document IS NULL
    OR jsonb_typeof(visual_document) = 'object'
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
        FROM email_template_version
        WHERE visual_document IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'Cannot roll back visual email documents: visual template data would be lost.';
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'ALTER TABLE email_template_version DROP CONSTRAINT chk_email_template_version_visual_document'
        );

        $this->addSql(
            'ALTER TABLE email_template_version DROP COLUMN visual_document'
        );
    }
}
