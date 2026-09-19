<?php

declare(strict_types=1);

namespace App\Command;

use App\Message\DeliverWebhook;
use App\Workspace\LegacyApiWorkspace;
use Doctrine\DBAL\Connection;
use Doctrine\DBAL\ParameterType;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Messenger\MessageBusInterface;
use Throwable;

#[AsCommand(
    name: 'app:webhook-outbox',
    description: 'Materialize and enqueue webhook deliveries.',
)]
final class WebhookOutboxCommand extends Command
{
    public function __construct(
        private readonly Connection $connection,
        private readonly MessageBusInterface $messageBus,
        private readonly LegacyApiWorkspace $legacyApiWorkspace,
    ) {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->addOption(
                'once',
                null,
                InputOption::VALUE_NONE,
                'Run one outbox pass.',
            )
            ->addOption(
                'batch',
                null,
                InputOption::VALUE_REQUIRED,
                'Maximum jobs queued per pass.',
                '50',
            )
            ->addOption(
                'sleep-ms',
                null,
                InputOption::VALUE_REQUIRED,
                'Delay between passes.',
                '1000',
            );
    }

    protected function execute(
        InputInterface $input,
        OutputInterface $output,
    ): int {
        $batch =
            filter_var(
                $input->getOption(
                    'batch',
                ),
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 1,
                        'max_range' => 500,
                    ],
                ],
            );

        $sleep =
            filter_var(
                $input->getOption(
                    'sleep-ms',
                ),
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 100,
                        'max_range' => 60000,
                    ],
                ],
            );

        if (
            !is_int($batch)
            || !is_int($sleep)
        ) {
            return Command::INVALID;
        }

        do {
            [
                $created,
                $queued,
            ] = $this->runPass(
                $batch,
            );

            if (
                $created > 0
                || $queued > 0
            ) {
                $output->writeln(
                    sprintf(
                        'OUTBOX created=%d queued=%d',
                        $created,
                        $queued,
                    ),
                );
            }

            if (
                $input->getOption(
                    'once',
                )
            ) {
                break;
            }

            usleep(
                $sleep * 1000,
            );
        } while (true);

        return Command::SUCCESS;
    }

    /**
     * @return array{int, int}
     */
    private function runPass(
        int $batch,
    ): array {
        $legacyWorkspaceId =
            $this
                ->legacyApiWorkspace
                ->id();

        $this->connection
            ->beginTransaction();

        try {
            /*
             * Materialize each endpoint/event pair exactly once.
             *
             * starts_after_event_id prevents historical events from
             * being sent when a new webhook is registered.
             */
            $created =
                $this->connection
                    ->executeStatement(
                        <<<'SQL'
INSERT INTO webhook_delivery (
    public_id,
    webhook_endpoint_id,
    outbound_message_event_id,
    status,
    attempt_count,
    queued_at,
    next_attempt_at,
    succeeded_at,
    last_error,
    created_at
)
SELECT
    'whd_' || md5(
        we.id::text
        || ':'
        || ome.id::text
    ),
    we.id,
    ome.id,
    'pending',
    0,
    NULL,
    NULL,
    NULL,
    NULL,
    timezone('UTC', CURRENT_TIMESTAMP)
FROM webhook_endpoint we
INNER JOIN webhook_endpoint_subscription wes
    ON wes.webhook_endpoint_id = we.id
INNER JOIN outbound_message_event ome
    ON ome.event_type = wes.event_type
   AND ome.id > we.starts_after_event_id
INNER JOIN outbound_message om
    ON om.id = ome.outbound_message_id
WHERE we.enabled = TRUE
  AND COALESCE(
      we.workspace_id,
      :legacy_workspace_id
  ) = COALESCE(
      om.workspace_id,
      :legacy_workspace_id
  )
ON CONFLICT (
    webhook_endpoint_id,
    outbound_message_event_id
)
DO NOTHING
SQL,
                        [
                            'legacy_workspace_id'
                                => $legacyWorkspaceId,
                        ],
                        [
                            'legacy_workspace_id'
                                => ParameterType::INTEGER,
                        ],
                    );

            $rows =
                $this->connection
                    ->executeQuery(
                        <<<'SQL'
SELECT id
FROM webhook_delivery
WHERE status = 'pending'
  AND queued_at IS NULL
  AND (
      next_attempt_at IS NULL
      OR next_attempt_at
         <= timezone(
             'UTC',
             CURRENT_TIMESTAMP
         )
  )
ORDER BY id ASC
LIMIT :batch
FOR UPDATE SKIP LOCKED
SQL,
                        [
                            'batch'
                                => $batch,
                        ],
                        [
                            'batch'
                                => ParameterType::INTEGER,
                        ],
                    )
                    ->fetchAllAssociative();

            foreach ($rows as $row) {
                $id = (int) $row['id'];

                $this->connection
                    ->executeStatement(
                        <<<'SQL'
UPDATE webhook_delivery
SET queued_at =
    timezone(
        'UTC',
        CURRENT_TIMESTAMP
    )
WHERE id = :id
SQL,
                        [
                            'id' => $id,
                        ],
                        [
                            'id'
                                => ParameterType::INTEGER,
                        ],
                    );

                /*
                 * Doctrine Messenger uses the same DB connection.
                 * The queue insert therefore commits atomically with
                 * queued_at and the outbox rows.
                 */
                $this->messageBus
                    ->dispatch(
                        new DeliverWebhook(
                            $id,
                        ),
                    );
            }

            $this->connection
                ->commit();

            return [
                $created,
                count($rows),
            ];
        } catch (Throwable $exception) {
            if (
                $this->connection
                    ->isTransactionActive()
            ) {
                $this->connection
                    ->rollBack();
            }

            throw $exception;
        }
    }
}
