<?php

declare(strict_types=1);

namespace App\Command;

use App\Entity\OutboundMessage;
use App\Entity\OutboundMessageEvent;
use App\Enum\OutboundMessageEventType;
use App\Mail\PostfixDeliveryFeedback;
use App\Mail\PostfixDeliveryLogParser;
use App\Suppression\EmailSuppressionService;
use Doctrine\ORM\EntityManagerInterface;
use LogicException;
use RuntimeException;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Throwable;

#[AsCommand(
    name: 'app:observe-postfix-delivery',
    description: 'Persist authenticated Postfix delivery outcomes.',
)]
final class ObservePostfixDeliveryCommand extends Command
{
    public function __construct(
        private readonly EntityManagerInterface $entityManager,
        private readonly PostfixDeliveryLogParser $parser,
        private readonly EmailSuppressionService $suppressions,
    ) {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addOption(
            'file',
            null,
            InputOption::VALUE_REQUIRED,
            'Postfix delivery log file.',
            '/var/log/postfix/heymail.log',
        );
    }

    protected function execute(
        InputInterface $input,
        OutputInterface $output,
    ): int {
        $path = $input->getOption(
            'file',
        );

        if (
            !is_string($path)
            || $path === ''
            || !str_starts_with(
                $path,
                '/',
            )
        ) {
            throw new RuntimeException(
                'Postfix log path must be absolute.',
            );
        }

        $output->writeln(
            sprintf(
                'OBSERVER file=%s',
                $path,
            ),
        );

        /*
         * Do not keep one PHP stream permanently at EOF.
         *
         * Postfix writes from another container through a shared volume.
         * Reopening from a durable byte offset makes appended data visible
         * reliably and also survives truncation/recreation of the log.
         */
        $offset = 0;

        while (true) {
            if (!is_readable($path)) {
                usleep(200000);

                continue;
            }

            clearstatcache(
                true,
                $path,
            );

            $size = filesize(
                $path,
            );

            if ($size === false) {
                usleep(200000);

                continue;
            }

            if ($size < $offset) {
                /*
                 * Log was truncated/recreated.
                 *
                 * Reset the parser because queue-id mappings belonging
                 * to the old log generation are no longer trustworthy.
                 */
                $offset = 0;

                $this->parser->reset();
            }

            if ($size === $offset) {
                usleep(200000);

                continue;
            }

            $handle = fopen(
                $path,
                'rb',
            );

            if ($handle === false) {
                usleep(200000);

                continue;
            }

            try {
                if (
                    $offset > 0
                    && fseek(
                        $handle,
                        $offset,
                        SEEK_SET,
                    ) !== 0
                ) {
                    throw new RuntimeException(
                        'Unable to seek Postfix delivery log.',
                    );
                }

                while (
                    ($line = fgets($handle))
                    !== false
                ) {
                    $position = ftell(
                        $handle,
                    );

                    if ($position !== false) {
                        $offset = $position;
                    }

                    $feedback =
                        $this->parser->consume(
                            $line,
                        );

                    if ($feedback === null) {
                        continue;
                    }

                    $this->persistFeedback(
                        $feedback,
                        $output,
                    );
                }
            } finally {
                fclose(
                    $handle,
                );
            }

            usleep(200000);
        }
    }

    private function persistFeedback(
        PostfixDeliveryFeedback $feedback,
        OutputInterface $output,
    ): void {
        $existing = $this
            ->entityManager
            ->getRepository(
                OutboundMessageEvent::class,
            )
            ->findOneBy([
                'sourceEventId'
                    => $feedback->sourceEventId,
            ]);

        if (
            $existing
            instanceof OutboundMessageEvent
        ) {
            $this->entityManager->clear();

            return;
        }

        $message =
            $this->entityManager->find(
                OutboundMessage::class,
                $feedback->outboundMessageId,
            );

        if (
            !$message
            instanceof OutboundMessage
        ) {
            $this->entityManager->clear();

            return;
        }

        if (
            $feedback->type
                === OutboundMessageEventType::BOUNCED
            && str_starts_with(
                $feedback->smtpStatus,
                '5.',
            )
        ) {
            $workspaceId =
                $message->getWorkspaceId();

            if (
                !is_int($workspaceId)
                || $workspaceId < 1
            ) {
                throw new RuntimeException(
                    'Bounced message has no valid workspace.',
                );
            }

            $this->suppressions->suppressGlobal(
                workspaceId: $workspaceId,
                email: $feedback->recipient,
                reason: 'hard_bounce',
                sourceOutboundMessageId:
                    $feedback->outboundMessageId,
                sourceEventId:
                    $feedback->sourceEventId,
            );
        }

        try {
            $message->recordDeliveryFeedback(
                type: $feedback->type,
                recipientHash: hash(
                    'sha256',
                    strtolower(
                        $feedback->recipient,
                    ),
                ),
                smtpStatus: $feedback->smtpStatus,
                detail: $feedback->detail,
                sourceEventId: $feedback->sourceEventId,
            );

            $this->entityManager->flush();
        } catch (LogicException $exception) {
            $output->writeln(
                sprintf(
                    'IGNORED message=%d reason=%s',
                    $feedback->outboundMessageId,
                    $exception->getMessage(),
                ),
            );

            $this->entityManager->clear();

            return;
        } catch (Throwable $exception) {
            $this->entityManager->clear();

            throw $exception;
        }

        $output->writeln(
            sprintf(
                'DELIVERY message=%d event=%s smtp=%s',
                $feedback->outboundMessageId,
                $feedback->type->value,
                $feedback->smtpStatus,
            ),
        );

        $this->entityManager->clear();
    }
}
