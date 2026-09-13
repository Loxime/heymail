<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260913150000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add persistent hourly API send request quotas.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
CREATE TABLE api_send_quota_hour (
    api_key_fingerprint VARCHAR(64) NOT NULL,
    window_started_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    request_count INTEGER NOT NULL,
    PRIMARY KEY (
        api_key_fingerprint,
        window_started_at
    ),
    CHECK (request_count >= 1)
)
SQL
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'DROP TABLE api_send_quota_hour'
        );
    }
}
