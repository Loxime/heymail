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
        private OutboundMessagePayloadCryptor $payloadCryptor,
        private MessageBusInterface $messageBus,
    ) {
    }

    public function submit(
        string $idempotencyKey,
        OutboundEmailPayload $payload,
        int $workspaceId,
    ): OutboundMessageSubmission {
        if ($workspaceId < 1) {
            throw new \InvalidArgumentException(
                'Invalid workspace.',
            );
        }

        $candidate = new OutboundMessage(
            idempotencyKey: $idempotencyKey,
            workspaceId: $workspaceId,
        );

        $idempotencyHash =
            $candidate->getIdempotencyKeyHash();

        $lockKey = sprintf(
            '%d:%s',
            $workspaceId,
            $idempotencyHash,
        );

        $connection =
            $this->entityManager->getConnection();

        $connection->beginTransaction();

        try {
            $connection->executeQuery(
                <<<'SQL'
SELECT pg_advisory_xact_lock(
    hashtextextended(:lock_key, 0)
)
SQL,
                [
                    'lock_key'
                        => $lockKey,
                ],
            );

            $existing = $this
                ->entityManager
                ->getRepository(
                    OutboundMessage::class,
                )
                ->findOneBy([
                    'workspaceId'
                        => $workspaceId,
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

                $storedPayload = $this
                    ->entityManager
                    ->getRepository(
                        OutboundMessagePayload::class,
                    )
                    ->findOneBy([
                        'outboundMessage'
                            => $existing,
                    ]);

                if (
                    !$storedPayload
                    instanceof OutboundMessagePayload
                ) {
                    throw new RuntimeException(
                        'Existing outbound message has no encrypted payload.',
                    );
                }

                $existingPayload =
                    $this->payloadCryptor->decrypt(
                        $existing,
                        $storedPayload
                            ->encryptedPayload(),
                    );

                if (
                    $existingPayload->toArray()
                    !== $payload->toArray()
                ) {
                    throw new IdempotencyConflictException(
                        'Idempotency key is already associated with another payload.',
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
                $this->payloadCryptor->encrypt(
                    $candidate,
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
