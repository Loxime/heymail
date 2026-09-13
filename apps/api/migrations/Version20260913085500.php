<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260913085500 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add delivery event time index for dashboard aggregation.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
CREATE INDEX idx_outbound_message_event_occurred_type
ON outbound_message_event (
    occurred_at,
    event_type
)
SQL
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            <<<'SQL'
DROP INDEX idx_outbound_message_event_occurred_type
SQL
        );
    }
}
