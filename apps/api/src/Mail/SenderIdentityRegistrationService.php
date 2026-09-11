<?php

declare(strict_types=1);

namespace App\Mail;

use App\Entity\SenderIdentity;
use App\Entity\SendingDomain;
use App\Enum\SendingDomainStatus;
use Doctrine\ORM\EntityManagerInterface;
use Throwable;

final readonly class SenderIdentityRegistrationService
{
    public function __construct(
        private EntityManagerInterface $entityManager,
    ) {
    }

    public function register(
        string $rawEmail,
    ): SenderIdentityRegistration {
        $email =
            new SenderEmailAddress(
                $rawEmail,
            );

        $connection =
            $this
                ->entityManager
                ->getConnection();

        $connection
            ->beginTransaction();

        try {
            /*
             * Serialize registration of one canonical sender address.
             */
            $connection
                ->executeQuery(
                    <<<'SQL'
SELECT pg_advisory_xact_lock(
    hashtextextended(:email, 0)
)
SQL,
                    [
                        'email'
                            => $email->value,
                    ],
                );

            $existing =
                $this
                    ->entityManager
                    ->getRepository(
                        SenderIdentity::class,
                    )
                    ->findOneBy([
                        'email'
                            => $email->value,
                    ]);

            if (
                $existing
                instanceof SenderIdentity
            ) {
                $connection
                    ->commit();

                return new SenderIdentityRegistration(
                    sender: $existing,
                    replayed: true,
                );
            }

            $domain =
                $this
                    ->entityManager
                    ->getRepository(
                        SendingDomain::class,
                    )
                    ->findOneBy([
                        'domain'
                            => $email->domain,
                    ]);

            if (
                !$domain
                instanceof SendingDomain
                || $domain->getStatus()
                    !== SendingDomainStatus::VERIFIED
            ) {
                throw new SenderDomainNotVerifiedException(
                    'Sender domain is not verified.',
                );
            }

            $sender =
                new SenderIdentity(
                    $domain,
                    $email,
                );

            $this
                ->entityManager
                ->persist(
                    $sender,
                );

            $this
                ->entityManager
                ->flush();

            $connection
                ->commit();

            return new SenderIdentityRegistration(
                sender: $sender,
                replayed: false,
            );
        } catch (Throwable $exception) {
            if (
                $connection
                    ->isTransactionActive()
            ) {
                $connection
                    ->rollBack();
            }

            throw $exception;
        }
    }
}
