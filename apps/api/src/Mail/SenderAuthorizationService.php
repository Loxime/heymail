<?php

declare(strict_types=1);

namespace App\Mail;

use App\Entity\SenderIdentity;
use Doctrine\ORM\EntityManagerInterface;
use InvalidArgumentException;

final readonly class SenderAuthorizationService
{
    public function __construct(
        private EntityManagerInterface $entityManager,
    ) {
    }

    public function authorizes(
        EmailAddress $from,
    ): bool {
        try {
            $canonical =
                new SenderEmailAddress(
                    $from->email,
                );
        } catch (InvalidArgumentException) {
            return false;
        }

        $sender =
            $this
                ->entityManager
                ->getRepository(
                    SenderIdentity::class,
                )
                ->findOneBy([
                    'email'
                        => $canonical->value,
                ]);

        return $sender
            instanceof SenderIdentity
            && $sender->isAuthorized();
    }
}
