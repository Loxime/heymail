<?php

declare(strict_types=1);

namespace App\Command;

use App\Entity\OutboundMessage;
use App\Entity\OutboundMessageEvent;
use App\Entity\OutboundMessagePayload;
use App\Mail\DsnSpoolEvent;
use App\Mail\OutboundEmailPayloadCipher;
use Doctrine\ORM\EntityManagerInterface;
use InvalidArgumentException;
use LogicException;
use RuntimeException;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Throwable;

#[AsCommand(
    name: 'app:consume-dsn-spool',
    description: 'Persist authenticated asynchronous DSN events.',
)]
final class ConsumeDsnSpoolCommand extends Command
{
    public function __construct(
        private readonly EntityManagerInterface $entityManager,
        private readonly OutboundEmailPayloadCipher $payloadCipher,
    ) {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->addOption(
                'directory',
                null,
                InputOption::VALUE_REQUIRED,
                'DSN spool directory.',
                '/events',
            )
            ->addOption(
                'once',
                null,
                InputOption::VALUE_NONE,
                'Process one spool pass and exit.',
            )
            ->addOption(
                'sleep-ms',
                null,
                InputOption::VALUE_REQUIRED,
                'Idle sleep in milliseconds.',
                '500',
            );
    }

    protected function execute(
        InputInterface $input,
        OutputInterface $output,
    ): int {
        $directory = $input->getOption(
            'directory',
        );

        if (
            !is_string($directory)
            || $directory === ''
            || !str_starts_with(
                $directory,
                '/',
            )
        ) {
            throw new RuntimeException(
                'DSN spool directory must be absolute.',
            );
        }

        $directory = rtrim(
            $directory,
            '/',
        );

        if (
            !is_dir($directory)
            || !is_readable($directory)
            || !is_writable($directory)
        ) {
            throw new RuntimeException(
                'DSN spool directory is unavailable.',
            );
        }

        $sleep = filter_var(
            $input->getOption(
                'sleep-ms',
            ),
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 100,
                    'max_range' => 10000,
                ],
            ],
        );

        if (!is_int($sleep)) {
            throw new RuntimeException(
                'Invalid DSN worker sleep interval.',
            );
        }

        $once = (bool) $input->getOption(
            'once',
        );

        $output->writeln(
            sprintf(
                'DSN-WORKER directory=%s',
                $directory,
            ),
        );

        do {
            $count = $this->consumePass(
                $directory,
                $output,
            );

            if ($once) {
                return Command::SUCCESS;
            }

            if ($count === 0) {
                usleep(
                    $sleep * 1000,
                );
            }
        } while (true);
    }

    private function consumePass(
        string $directory,
        OutputInterface $output,
    ): int {
        $files = glob(
            $directory . '/*.json',
        );

        if ($files === false) {
            throw new RuntimeException(
                'Unable to enumerate DSN spool.',
            );
        }

        sort(
            $files,
            SORT_STRING,
        );

        foreach ($files as $path) {
            $this->processFile(
                $path,
                $output,
            );
        }

        return count(
            $files,
        );
    }

    private function processFile(
        string $path,
        OutputInterface $output,
    ): void {
        if (
            is_link($path)
            || !is_file($path)
        ) {
            return;
        }

        $handle = @fopen(
            $path,
            'rb',
        );

        if ($handle === false) {
            throw new RuntimeException(
                'Unable to open DSN spool file.',
            );
        }

        if (
            !flock(
                $handle,
                LOCK_EX | LOCK_NB,
            )
        ) {
            fclose(
                $handle,
            );

            return;
        }

        try {
            $stat = fstat(
                $handle,
            );

            if (
                $stat === false
                || $stat['size'] < 2
                || $stat['size'] > 8192
            ) {
                $this->quarantine(
                    $path,
                    'invalid',
                    $output,
                );

                return;
            }

            $json = stream_get_contents(
                $handle,
            );

            if (!is_string($json)) {
                throw new RuntimeException(
                    'Unable to read DSN spool file.',
                );
            }

            try {
                $event = DsnSpoolEvent::fromJson(
                    $json,
                );
            } catch (InvalidArgumentException) {
                $this->quarantine(
                    $path,
                    'invalid',
                    $output,
                );

                return;
            }

            if (
                basename($path)
                !== $event->sourceEventId . '.json'
            ) {
                $this->quarantine(
                    $path,
                    'invalid',
                    $output,
                );

                return;
            }

            $existing = $this
                ->entityManager
                ->getRepository(
                    OutboundMessageEvent::class,
                )
                ->findOneBy([
                    'sourceEventId'
                        => $event->sourceEventId,
                ]);

            if (
                $existing
                instanceof OutboundMessageEvent
            ) {
                $this->entityManager->clear();

                $this->removePersistedFile(
                    $path,
                );

                $output->writeln(
                    'DSN duplicate removed',
                );

                return;
            }

            $message = $this
                ->entityManager
                ->find(
                    OutboundMessage::class,
                    $event->messageId,
                );

            if (
                !$message
                instanceof OutboundMessage
            ) {
                $this->entityManager->clear();

                $this->quarantine(
                    $path,
                    'orphaned',
                    $output,
                );

                return;
            }

            $storedPayload = $this
                ->entityManager
                ->getRepository(
                    OutboundMessagePayload::class,
                )
                ->findOneBy([
                    'outboundMessage'
                        => $message,
                ]);

            if (
                !$storedPayload
                instanceof OutboundMessagePayload
            ) {
                $this->entityManager->clear();

                $this->quarantine(
                    $path,
                    'rejected',
                    $output,
                );

                return;
            }

            try {
                $payload = $this
                    ->payloadCipher
                    ->decrypt(
                        $message
                            ->getIdempotencyKeyHash(),
                        $storedPayload
                            ->encryptedPayload(),
                    );
            } catch (Throwable) {
                $this->entityManager->clear();

                $this->quarantine(
                    $path,
                    'rejected',
                    $output,
                );

                return;
            }

            $recipientAllowed = false;

            foreach ($payload->to as $recipient) {
                $expectedHash = hash(
                    'sha256',
                    strtolower(
                        $recipient->email,
                    ),
                );

                if (
                    hash_equals(
                        $expectedHash,
                        $event->recipientHash,
                    )
                ) {
                    $recipientAllowed = true;

                    break;
                }
            }

            if (!$recipientAllowed) {
                $this->entityManager->clear();

                $this->quarantine(
                    $path,
                    'forged',
                    $output,
                );

                return;
            }

            try {
                $message->recordDeliveryFeedback(
                    type: $event->type,
                    recipientHash:
                        $event->recipientHash,
                    smtpStatus:
                        $event->smtpStatus,
                    detail:
                        $event->detail,
                    sourceEventId:
                        $event->sourceEventId,
                );

                $this->entityManager->flush();
            } catch (LogicException) {
                $this->entityManager->clear();

                $this->quarantine(
                    $path,
                    'rejected',
                    $output,
                );

                return;
            } catch (Throwable $exception) {
                $this->entityManager->clear();

                throw $exception;
            }

            $this->entityManager->clear();

            /*
             * DB commit happened first.
             *
             * If unlink fails, the file remains. On the next run the
             * source_event_id lookup takes the idempotent duplicate path.
             */
            $this->removePersistedFile(
                $path,
            );

            $output->writeln(
                sprintf(
                    'DSN message=%d event=%s smtp=%s',
                    $event->messageId,
                    $event->type->value,
                    $event->smtpStatus,
                ),
            );
        } finally {
            flock(
                $handle,
                LOCK_UN,
            );

            fclose(
                $handle,
            );
        }
    }

    private function removePersistedFile(
        string $path,
    ): void {
        if (!@unlink($path)) {
            throw new RuntimeException(
                'Unable to remove persisted DSN event.',
            );
        }
    }

    private function quarantine(
        string $path,
        string $reason,
        OutputInterface $output,
    ): void {
        $target =
            $path
            . '.'
            . $reason;

        if (file_exists($target)) {
            if (!@unlink($path)) {
                throw new RuntimeException(
                    'Unable to remove duplicate quarantined DSN event.',
                );
            }

            $output->writeln(
                sprintf(
                    'DSN quarantine duplicate removed reason=%s',
                    $reason,
                ),
            );

            return;
        }

        if (!@rename(
            $path,
            $target,
        )) {
            throw new RuntimeException(
                'Unable to quarantine DSN event.',
            );
        }

        $output->writeln(
            sprintf(
                'DSN quarantined reason=%s',
                $reason,
            ),
        );
    }
}
