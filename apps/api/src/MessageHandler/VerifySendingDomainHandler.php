<?php

declare(strict_types=1);

namespace App\MessageHandler;

use App\Entity\SendingDomain;
use App\Enum\SendingDomainStatus;
use App\Mail\DomainOwnershipVerifier;
use App\Message\ProvisionSendingDomainDkim;
use App\Message\VerifySendingDomain;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;
use Symfony\Component\Messenger\MessageBusInterface;

#[AsMessageHandler]
final readonly class VerifySendingDomainHandler
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private DomainOwnershipVerifier $verifier,
        private MessageBusInterface $messageBus,
    ) {
    }

    public function __invoke(
        VerifySendingDomain $message,
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

        $status =
            $domain
                ->getStatus();

        if (
            $status
            === SendingDomainStatus::DISABLED
        ) {
            return;
        }

        if (
            $status
            === SendingDomainStatus::VERIFIED
        ) {
            if (
                !$domain->isDkimReady()
            ) {
                $this->queueDkimProvisioning(
                    $domain,
                );
            }

            return;
        }

        $owned =
            $this->verifier
                ->verify(
                    $domain,
                );

        $checkedAt =
            new DateTimeImmutable(
                'now',
                new DateTimeZone('UTC'),
            );

        if ($owned) {
            $domain
                ->markVerified(
                    $checkedAt,
                );

            /*
             * Persist VERIFIED before creating the DKIM job.
             *
             * On a dispatch failure, Messenger retries this verification
             * job. The VERIFIED branch above then queues provisioning
             * again, making the transition recoverable.
             */
            $this->entityManager
                ->flush();

            $this->queueDkimProvisioning(
                $domain,
            );

            return;
        }

        $domain
            ->markVerificationChecked(
                $checkedAt,
            );

        $this->entityManager
            ->flush();
    }

    private function queueDkimProvisioning(
        SendingDomain $domain,
    ): void {
        $domainId =
            $domain->getId();

        if (
            !is_int(
                $domainId,
            )
            || $domainId < 1
        ) {
            throw new UnrecoverableMessageHandlingException(
                'Persisted sending domain has no valid identifier.',
            );
        }

        $this
            ->messageBus
            ->dispatch(
                new ProvisionSendingDomainDkim(
                    $domainId,
                ),
            );
    }
}
