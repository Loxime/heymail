<?php

declare(strict_types=1);

namespace App\Command;

use App\Campaign\CampaignBatchProcessor;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

#[AsCommand(
    name: 'app:campaign:worker',
    description: 'Process due campaign batches without direct SMTP access.',
)]
final class CampaignWorkerCommand extends Command
{
    public function __construct(
        private readonly CampaignBatchProcessor $processor,
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
                'Process at most one campaign batch.',
            )
            ->addOption(
                'sleep',
                null,
                InputOption::VALUE_REQUIRED,
                'Idle sleep in seconds.',
                '1',
            )
            ->addOption(
                'time-limit',
                null,
                InputOption::VALUE_REQUIRED,
                'Maximum runtime in seconds; 0 means unlimited.',
                '3600',
            );
    }

    protected function execute(
        InputInterface $input,
        OutputInterface $output,
    ): int {
        $sleep = filter_var(
            $input->getOption('sleep'),
            FILTER_VALIDATE_INT,
            ['options' => ['min_range' => 1, 'max_range' => 60]],
        );

        $timeLimit = filter_var(
            $input->getOption('time-limit'),
            FILTER_VALIDATE_INT,
            ['options' => ['min_range' => 0, 'max_range' => 86400]],
        );

        if (!is_int($sleep) || !is_int($timeLimit)) {
            $output->writeln(
                '<error>Invalid worker timing options.</error>',
            );
            return Command::INVALID;
        }

        $once = (bool) $input->getOption('once');
        $started = time();

        do {
            $processed = $this->processor->processNextBatch();

            if ($processed) {
                $output->writeln(
                    '<info>Processed one campaign batch.</info>',
                    OutputInterface::VERBOSITY_VERBOSE,
                );
            }

            if ($once) {
                break;
            }

            if (
                $timeLimit > 0
                && time() - $started >= $timeLimit
            ) {
                break;
            }

            if (!$processed) {
                sleep($sleep);
            }
        } while (true);

        return Command::SUCCESS;
    }
}
