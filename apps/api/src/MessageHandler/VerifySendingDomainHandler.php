<?php

declare(strict_types=1);

namespace App\MessageHandler;

use App\Entity\SendingDomain;
use App\Enum\SendingDomainStatus;
use App\Mail\DomainOwnershipVerifier;
use App\Message\VerifySendingDomain;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;

#[AsMessageHandler]
final readonly class VerifySendingDomainHandler
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private DomainOwnershipVerifier $verifier,
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
            === SendingDomainStatus::VERIFIED
            || $status
            === SendingDomainStatus::DISABLED
        ) {
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
        } else {
            $domain
                ->markVerificationChecked(
                    $checkedAt,
                );
        }

        $this->entityManager
            ->flush();
    }
}
