<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260919180000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Contract workspace ownership columns to NOT NULL.';
    }

    public function up(Schema $schema): void
    {
        /*
         * Fail closed. Expand backfilled historical rows and v1.2 writes
         * assign ownership explicitly. Do not guess ownership here.
         */
        $this->addSql(
            <<<'SQL'
DO $$
DECLARE
    sending_domain_nulls BIGINT;
    outbound_message_nulls BIGINT;
    webhook_endpoint_nulls BIGINT;
BEGIN
    SELECT COUNT(*) INTO sending_domain_nulls
    FROM sending_domain
    WHERE workspace_id IS NULL;

    SELECT COUNT(*) INTO outbound_message_nulls
    FROM outbound_message
    WHERE workspace_id IS NULL;

    SELECT COUNT(*) INTO webhook_endpoint_nulls
    FROM webhook_endpoint
    WHERE workspace_id IS NULL;

    IF
        sending_domain_nulls <> 0
        OR outbound_message_nulls <> 0
        OR webhook_endpoint_nulls <> 0
    THEN
        RAISE EXCEPTION
            'Cannot enforce workspace ownership contract: sending_domain=%, outbound_message=%, webhook_endpoint=% NULL workspace rows',
            sending_domain_nulls,
            outbound_message_nulls,
            webhook_endpoint_nulls;
    END IF;
END
$$
SQL
        );

        $this->addSql(
            'ALTER TABLE sending_domain ALTER COLUMN workspace_id SET NOT NULL'
        );

        $this->addSql(
            'ALTER TABLE outbound_message ALTER COLUMN workspace_id SET NOT NULL'
        );

        $this->addSql(
            'ALTER TABLE webhook_endpoint ALTER COLUMN workspace_id SET NOT NULL'
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'ALTER TABLE webhook_endpoint ALTER COLUMN workspace_id DROP NOT NULL'
        );

        $this->addSql(
            'ALTER TABLE outbound_message ALTER COLUMN workspace_id DROP NOT NULL'
        );

        $this->addSql(
            'ALTER TABLE sending_domain ALTER COLUMN workspace_id DROP NOT NULL'
        );
    }
}
