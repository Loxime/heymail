<?php

declare(strict_types=1);

namespace App\MessageHandler;

use App\Entity\OutboundMessage;
use App\Entity\OutboundMessagePayload;
use App\Enum\OutboundMessageStatus;
use App\Mail\OutboundEmailPayloadCipher;
use App\Mail\OutboundMessageSubmitter;
use App\Message\SendOutboundEmail;
use Doctrine\ORM\EntityManagerInterface;
use InvalidArgumentException;
use JsonException;
use RuntimeException;
use SodiumException;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;

#[AsMessageHandler(sign: true)]
final readonly class SendOutboundEmailHandler
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private OutboundEmailPayloadCipher $payloadCipher,
        private OutboundMessageSubmitter $submitter,
    ) {
    }

    public function __invoke(
        SendOutboundEmail $message,
    ): void {
        $outboundMessage =
            $this->entityManager->find(
                OutboundMessage::class,
                $message->outboundMessageId,
            );

        if (
            !$outboundMessage
            instanceof OutboundMessage
        ) {
            throw new UnrecoverableMessageHandlingException(
                sprintf(
                    'Outbound message %d does not exist.',
                    $message->outboundMessageId,
                ),
            );
        }

        if (
            $outboundMessage->getStatus()
            === OutboundMessageStatus::SUBMITTED
        ) {
            return;
        }

        $storedPayload = $this
            ->entityManager
            ->getRepository(
                OutboundMessagePayload::class,
            )
            ->findOneBy([
                'outboundMessage' => $outboundMessage,
            ]);

        if (
            !$storedPayload
            instanceof OutboundMessagePayload
        ) {
            throw new UnrecoverableMessageHandlingException(
                sprintf(
                    'Outbound message %d has no encrypted payload.',
                    $message->outboundMessageId,
                ),
            );
        }

        try {
            $payload =
                $this->payloadCipher->decrypt(
                    $outboundMessage
                        ->getIdempotencyKeyHash(),
                    $storedPayload
                        ->encryptedPayload(),
                );
        } catch (
            JsonException
            | InvalidArgumentException
            | RuntimeException
            | SodiumException $exception
        ) {
            throw new UnrecoverableMessageHandlingException(
                sprintf(
                    'Outbound message %d payload cannot be decrypted.',
                    $message->outboundMessageId,
                ),
                0,
                $exception,
            );
        }

        if (
            $outboundMessage->getStatus()
            === OutboundMessageStatus::QUEUED
        ) {
            $outboundMessage
                ->markReadyForSubmission();

            $this->entityManager->flush();
        }

        $this->submitter->submit(
            $message->outboundMessageId,
            $payload,
        );

        $outboundMessage->markSubmitted();

        $this->entityManager->flush();
    }
}
