<?php

declare(strict_types=1);

namespace App\MessageHandler;

use App\Entity\OutboundMessage;
use App\Entity\OutboundMessagePayload;
use App\Enum\OutboundMessageStatus;
use App\Mail\OutboundMessagePayloadCryptor;
use App\Mail\OutboundMessageSubmitter;
use App\Message\SendOutboundEmail;
use Doctrine\ORM\EntityManagerInterface;
use InvalidArgumentException;
use JsonException;
use RuntimeException;
use SodiumException;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;
use Throwable;

#[AsMessageHandler(sign: true)]
final readonly class SendOutboundEmailHandler
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private OutboundMessagePayloadCryptor $payloadCryptor,
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

        $status =
            $outboundMessage->getStatus();

        /*
         * Final states never trigger another SMTP submission.
         */
        if (
            $status === OutboundMessageStatus::SUBMITTED
            || $status === OutboundMessageStatus::SUBMISSION_UNCERTAIN
        ) {
            return;
        }

        /*
         * A redelivered Messenger job seeing SUBMITTING means that a
         * previous worker persisted the SMTP claim but never persisted
         * the final SUBMITTED state.
         *
         * The previous process may have died after receiving SMTP 250.
         * Resubmitting would therefore risk duplicate email delivery.
         */
        if (
            $status === OutboundMessageStatus::SUBMITTING
        ) {
            $outboundMessage
                ->markSubmissionUncertain();

            $this->entityManager->flush();

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
                $this->payloadCryptor->decrypt(
                    $outboundMessage,
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

        /*
         * QUEUED -> READY -> SUBMITTING is flushed once.
         *
         * PostgreSQL therefore durably records SUBMITTING before the
         * first SMTP operation takes place.
         */
        if (
            $outboundMessage->getStatus()
            === OutboundMessageStatus::QUEUED
        ) {
            $outboundMessage
                ->markReadyForSubmission();
        }

        if (
            $outboundMessage->getStatus()
            === OutboundMessageStatus::READY_FOR_SUBMISSION
        ) {
            $outboundMessage
                ->markSubmitting();

            $this->entityManager->flush();
        }

        if (
            $outboundMessage->getStatus()
            !== OutboundMessageStatus::SUBMITTING
        ) {
            throw new UnrecoverableMessageHandlingException(
                sprintf(
                    'Outbound message %d is not eligible for SMTP submission.',
                    $message->outboundMessageId,
                ),
            );
        }

        try {
            $this->submitter->submit(
                $message->outboundMessageId,
                $payload,
            );
        } catch (Throwable $exception) {
            /*
             * SMTP failures are conservative here.
             *
             * Once SUBMITTING was persisted, a transport exception does
             * not prove that the remote SMTP side rejected the message.
             * The connection may have failed while receiving the final
             * acknowledgement.
             *
             * Therefore automatic retries are disabled.
             */
            $outboundMessage
                ->markSubmissionUncertain();

            $this->entityManager->flush();

            throw new UnrecoverableMessageHandlingException(
                sprintf(
                    'Outbound message %d SMTP submission outcome is uncertain.',
                    $message->outboundMessageId,
                ),
                0,
                $exception,
            );
        }

        /*
         * submit() returning means the local Postfix boundary accepted
         * the message. Persist the definitive local submission state.
         */
        $outboundMessage
            ->markSubmitted();

        $this->entityManager->flush();
    }
}
