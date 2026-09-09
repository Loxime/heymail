<?php

declare(strict_types=1);

namespace App\Mail;

use App\Entity\OutboundMessage;
use App\Entity\OutboundMessagePayload;
use App\Message\SendOutboundEmail;
use Doctrine\ORM\EntityManagerInterface;
use RuntimeException;
use Symfony\Component\Messenger\MessageBusInterface;
use Throwable;

final readonly class OutboundMessageSubmissionService
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private OutboundEmailPayloadCipher $payloadCipher,
        private MessageBusInterface $messageBus,
    ) {
    }

    public function submit(
        string $idempotencyKey,
        OutboundEmailPayload $payload,
    ): OutboundMessageSubmission {
        $candidate = new OutboundMessage(
            $idempotencyKey,
        );

        $idempotencyHash =
            $candidate->getIdempotencyKeyHash();

        $connection =
            $this->entityManager->getConnection();

        $connection->beginTransaction();

        try {
            $connection->executeQuery(
                <<<'SQL'
SELECT pg_advisory_xact_lock(
    hashtextextended(:idempotency_hash, 0)
)
SQL,
                [
                    'idempotency_hash'
                        => $idempotencyHash,
                ],
            );

            $existing = $this
                ->entityManager
                ->getRepository(
                    OutboundMessage::class,
                )
                ->findOneBy([
                    'idempotencyKeyHash'
                        => $idempotencyHash,
                ]);

            if (
                $existing
                instanceof OutboundMessage
            ) {
                $existingId =
                    $existing->getId();

                if (
                    !is_int($existingId)
                    || $existingId < 1
                ) {
                    throw new RuntimeException(
                        'Existing outbound message has no valid identifier.',
                    );
                }

                $connection->commit();

                return new OutboundMessageSubmission(
                    messageId: $existingId,
                    status: $existing->getStatus(),
                    replayed: true,
                );
            }

            $encrypted =
                $this->payloadCipher->encrypt(
                    $idempotencyHash,
                    $payload,
                );

            $storedPayload =
                new OutboundMessagePayload(
                    $candidate,
                    $encrypted,
                );

            $this->entityManager->persist(
                $candidate,
            );

            $this->entityManager->persist(
                $storedPayload,
            );

            $this->entityManager->flush();

            $messageId =
                $candidate->getId();

            if (
                !is_int($messageId)
                || $messageId < 1
            ) {
                throw new RuntimeException(
                    'Outbound message did not receive a valid identifier.',
                );
            }

            $this->messageBus->dispatch(
                new SendOutboundEmail(
                    $messageId,
                ),
            );

            $connection->commit();

            return new OutboundMessageSubmission(
                messageId: $messageId,
                status: $candidate->getStatus(),
                replayed: false,
            );
        } catch (Throwable $exception) {
            if (
                $connection
                    ->isTransactionActive()
            ) {
                $connection->rollBack();
            }

            $this->entityManager->clear();

            throw $exception;
        }
    }
}
