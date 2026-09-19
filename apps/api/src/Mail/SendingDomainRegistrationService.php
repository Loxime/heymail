<?php

declare(strict_types=1);

namespace App\Mail;

use App\Entity\SendingDomain;
use Doctrine\ORM\EntityManagerInterface;
use Throwable;

final readonly class SendingDomainRegistrationService
{
    public function __construct(
        private EntityManagerInterface $entityManager,
    ) {
    }

    public function register(
        string $rawDomain,
        int $workspaceId,
    ): SendingDomainRegistration {
        if ($workspaceId < 1) {
            throw new \InvalidArgumentException(
                'Invalid workspace.',
            );
        }

        $domainName =
            new DomainName(
                $rawDomain,
            );

        $canonicalDomain =
            $domainName->value;

        $connection =
            $this->entityManager
                ->getConnection();

        $connection->beginTransaction();

        try {
            $connection->executeQuery(
                <<<'SQL'
SELECT pg_advisory_xact_lock(
    hashtextextended(:domain, 0)
)
SQL,
                [
                    'domain'
                        => $canonicalDomain,
                ],
            );

            $existing = $this
                ->entityManager
                ->getRepository(
                    SendingDomain::class,
                )
                ->findOneBy([
                    'domain'
                        => $canonicalDomain,
                ]);

            if (
                $existing
                instanceof SendingDomain
            ) {
                if (
                    $existing->getWorkspaceId() !== null
                    && $existing->getWorkspaceId()
                        !== $workspaceId
                ) {
                    throw new \InvalidArgumentException(
                        'Sending domain is already registered.',
                    );
                }

                $connection->commit();

                return new SendingDomainRegistration(
                    domain: $existing,
                    replayed: true,
                );
            }

            $domain =
                new SendingDomain(
                    domain: $domainName,
                    verificationToken: bin2hex(
                        random_bytes(32),
                    ),
                    workspaceId: $workspaceId,
                );

            $this->entityManager
                ->persist(
                    $domain,
                );

            $this->entityManager
                ->flush();

            $connection->commit();

            return new SendingDomainRegistration(
                domain: $domain,
                replayed: false,
            );
        } catch (Throwable $exception) {
            if (
                $connection
                    ->isTransactionActive()
            ) {
                $connection->rollBack();
            }

            throw $exception;
        }
    }
}
