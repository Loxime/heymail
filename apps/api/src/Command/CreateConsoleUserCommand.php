<?php

declare(strict_types=1);

namespace App\Command;

use App\Console\ConsoleAuthentication;
use App\Console\ConsoleUserProvisioner;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

#[AsCommand(
    name: 'app:console-user:create',
    description: 'Create a HeyMail console user.',
)]
final class CreateConsoleUserCommand extends Command
{
    public function __construct(
        private readonly Connection $connection,
        private readonly ConsoleUserProvisioner $provisioner,
    ) {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->addArgument(
                'email',
                InputArgument::REQUIRED,
                'Console login email.',
            )
            ->addArgument(
                'first-name',
                InputArgument::REQUIRED,
                'First name.',
            )
            ->addArgument(
                'last-name',
                InputArgument::REQUIRED,
                'Last name.',
            );
    }

    protected function execute(
        InputInterface $input,
        OutputInterface $output,
    ): int {
        $io = new SymfonyStyle(
            $input,
            $output,
        );

        try {
            $email = ConsoleAuthentication::normalizeEmail(
                (string) $input->getArgument('email'),
            );
        } catch (InvalidArgumentException $exception) {
            $io->error(
                $exception->getMessage(),
            );

            return Command::INVALID;
        }

        $firstName = trim(
            (string) $input->getArgument('first-name'),
        );

        $lastName = trim(
            (string) $input->getArgument('last-name'),
        );

        if (
            $firstName === ''
            || $lastName === ''
            || strlen($firstName) > 100
            || strlen($lastName) > 100
        ) {
            $io->error(
                'Invalid first or last name.',
            );

            return Command::INVALID;
        }

        if (
            $this->connection
                ->fetchOne(
                    'SELECT 1 FROM console_user WHERE email = :email',
                    [
                        'email' => $email,
                    ],
                ) !== false
        ) {
            $io->error(
                'A console user with this email already exists.',
            );

            return Command::FAILURE;
        }

        $password = $io->askHidden(
            'Password (minimum 12 characters)',
        );

        if (
            !is_string($password)
            || strlen($password) < 12
            || strlen($password) > 4096
        ) {
            $io->error(
                'Password must contain at least 12 characters.',
            );

            return Command::INVALID;
        }

        $confirmation = $io->askHidden(
            'Confirm password',
        );

        if ($confirmation !== $password) {
            $io->error(
                'Passwords do not match.',
            );

            return Command::INVALID;
        }

        $hash = password_hash(
            $password,
            PASSWORD_DEFAULT,
        );

        if (!is_string($hash)) {
            $io->error(
                'Unable to hash password.',
            );

            return Command::FAILURE;
        }

        $now = new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );

        try {
            $this->provisioner->create(
                email: $email,
                firstName: $firstName,
                lastName: $lastName,
                passwordHash: $hash,
                now: $now,
            );
        } catch (\Throwable) {
            $io->error(
                'Unable to create console user.',
            );

            return Command::FAILURE;
        }

        $io->success(
            sprintf(
                'Console user %s created.',
                $email,
            ),
        );

        return Command::SUCCESS;
    }
}
