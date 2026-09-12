<?php

declare(strict_types=1);

namespace App\MessageHandler;

use App\Entity\SendingDomain;
use App\Enum\SendingDomainStatus;
use App\Mail\DkimKeyProvisioner;
use App\Message\ProvisionSendingDomainDkim;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;
use Throwable;

#[AsMessageHandler]
final readonly class ProvisionSendingDomainDkimHandler
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private DkimKeyProvisioner $provisioner,
    ) {
    }

    public function __invoke(
        ProvisionSendingDomainDkim $message,
    ): void {
        $domain =
            $this->entityManager
                ->find(
                    SendingDomain::class,
                    $message->sendingDomainId,
                );

        if (
            !$domain
            instanceof SendingDomain
        ) {
            throw new UnrecoverableMessageHandlingException(
                sprintf(
                    'Sending domain %d does not exist.',
                    $message->sendingDomainId,
                ),
            );
        }

        if (
            $domain->getStatus()
            !== SendingDomainStatus::VERIFIED
        ) {
            return;
        }

        if (
            $domain->isDkimReady()
        ) {
            return;
        }

        $connection =
            $this
                ->entityManager
                ->getConnection();

        $connection
            ->beginTransaction();

        try {
            $connection
                ->executeQuery(
                    <<<'SQL'
SELECT pg_advisory_xact_lock(
    hashtextextended(:lock_key, 0)
)
SQL,
                    [
                        'lock_key'
                            => 'dkim:'
                                . $domain
                                    ->getDomain(),
                    ],
                );

            /*
             * A concurrent duplicate job may have completed while this
             * worker waited for the advisory lock.
             */
            $this
                ->entityManager
                ->refresh(
                    $domain,
                );

            if (
                $domain->getStatus()
                !== SendingDomainStatus::VERIFIED
            ) {
                $connection
                    ->commit();

                return;
            }

            if (
                $domain->isDkimReady()
            ) {
                $connection
                    ->commit();

                return;
            }

            /*
             * File publication happens before the database marker.
             *
             * If the worker dies after the atomic rename but before the
             * transaction commits, Messenger can safely retry: the
             * provisioner reuses the already published private key and
             * derives the same public key from it.
             */
            $material =
                $this
                    ->provisioner
                    ->provision(
                        $domain
                            ->getDomain(),
                    );

            $domain
                ->markDkimProvisioned(
                    $material->selector,
                    $material->publicKey,
                    new DateTimeImmutable(
                        'now',
                        new DateTimeZone(
                            'UTC',
                        ),
                    ),
                );

            $this
                ->entityManager
                ->flush();

            $connection
                ->commit();
        } catch (Throwable $exception) {
            if (
                $connection
                    ->isTransactionActive()
            ) {
                $connection
                    ->rollBack();
            }

            $this
                ->entityManager
                ->clear();

            throw $exception;
        }
    }
}
