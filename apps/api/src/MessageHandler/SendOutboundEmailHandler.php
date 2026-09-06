<?php

declare(strict_types=1);

namespace App\MessageHandler;

use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageStatus;
use App\Message\SendOutboundEmail;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;

#[AsMessageHandler(sign: true)]
final readonly class SendOutboundEmailHandler
{
    public function __construct(
        private EntityManagerInterface $entityManager,
    ) {
    }

    public function __invoke(SendOutboundEmail $message): void
    {
        $outboundMessage = $this->entityManager->find(
            OutboundMessage::class,
            $message->outboundMessageId,
        );

        if (!$outboundMessage instanceof OutboundMessage) {
            throw new UnrecoverableMessageHandlingException(
                sprintf(
                    'Outbound message %d does not exist.',
                    $message->outboundMessageId,
                ),
            );
        }

        if (
            $outboundMessage->getStatus()
            === OutboundMessageStatus::READY_FOR_SUBMISSION
        ) {
            return;
        }

        $outboundMessage->markReadyForSubmission();

        $this->entityManager->flush();
    }
}
