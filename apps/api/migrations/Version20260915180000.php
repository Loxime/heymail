<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260915180000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add console users, sessions, and favorite contacts.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
CREATE TABLE console_user (
    id BIGSERIAL NOT NULL,
    email VARCHAR(254) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uniq_console_user_email UNIQUE (email)
)
SQL
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE console_session (
    token_hash VARCHAR(64) NOT NULL,
    user_id BIGINT NOT NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    last_seen_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    expires_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (token_hash),
    CONSTRAINT fk_console_session_user
        FOREIGN KEY (user_id)
        REFERENCES console_user (id)
        ON DELETE CASCADE
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_console_session_user ON console_session (user_id)'
        );

        $this->addSql(
            'CREATE INDEX idx_console_session_expiry ON console_session (expires_at)'
        );

        $this->addSql(
            <<<'SQL'
CREATE TABLE console_favorite_contact (
    id BIGSERIAL NOT NULL,
    user_id BIGINT NOT NULL,
    email VARCHAR(254) NOT NULL,
    name VARCHAR(160) NULL,
    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uniq_console_favorite_contact UNIQUE (user_id, email),
    CONSTRAINT fk_console_favorite_contact_user
        FOREIGN KEY (user_id)
        REFERENCES console_user (id)
        ON DELETE CASCADE
)
SQL
        );

        $this->addSql(
            'CREATE INDEX idx_console_favorite_user ON console_favorite_contact (user_id, id)'
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE console_favorite_contact');
        $this->addSql('DROP TABLE console_session');
        $this->addSql('DROP TABLE console_user');
    }
}
