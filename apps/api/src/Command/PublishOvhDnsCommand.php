<?php

declare(strict_types=1);

namespace App\Command;

use App\Dns\OvhDnsPublisher;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

#[AsCommand(
    name: 'app:publish-ovh-dns',
    description: 'Reconcile HeyMail DNS records through OVH.',
)]
final class PublishOvhDnsCommand extends Command
{
    public function __construct(
        private readonly OvhDnsPublisher $publisher,
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
                'Run one reconciliation pass.',
            )
            ->addOption(
                'sleep-seconds',
                null,
                InputOption::VALUE_REQUIRED,
                'Delay between reconciliation passes.',
                '60',
            );
    }

    protected function execute(
        InputInterface $input,
        OutputInterface $output,
    ): int {
        $sleep =
            filter_var(
                $input->getOption(
                    'sleep-seconds',
                ),
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 5,
                        'max_range' => 3600,
                    ],
                ],
            );

        if (!is_int($sleep)) {
            return Command::INVALID;
        }

        do {
            $results =
                $this
                    ->publisher
                    ->publish();

            foreach ($results as $result) {
                $output->writeln(
                    sprintf(
                        'DNS record=%s action=%s',
                        $result['record'],
                        $result['action'],
                    ),
                );
            }

            $output->writeln(
                sprintf(
                    'DNS PASS records=%d',
                    count($results),
                ),
            );

            if (
                $input->getOption(
                    'once',
                )
            ) {
                break;
            }

            sleep($sleep);
        } while (true);

        return Command::SUCCESS;
    }
}
