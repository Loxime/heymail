<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260906172000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Align Messenger queue index name with Doctrine schema metadata';
    }

    public function up(Schema $schema): void
    {
        $this->addSql(
            'ALTER INDEX idx_messenger_queue '
            . 'RENAME TO IDX_75EA56E0FB7336F0E3BD61CE16BA31DBBF396750'
        );
    }

    public function down(Schema $schema): void
    {
        $this->addSql(
            'ALTER INDEX IDX_75EA56E0FB7336F0E3BD61CE16BA31DBBF396750 '
            . 'RENAME TO idx_messenger_queue'
        );
    }
}
