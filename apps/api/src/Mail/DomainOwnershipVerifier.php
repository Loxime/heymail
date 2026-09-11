<?php

declare(strict_types=1);

namespace App\Mail;

use App\Entity\SendingDomain;

final readonly class DomainOwnershipVerifier
{
    public function __construct(
        private TxtRecordResolver $resolver,
    ) {
    }

    public function verify(
        SendingDomain $domain,
    ): bool {
        $expected =
            $domain
                ->getVerificationRecordValue();

        foreach (
            $this->resolver->resolve(
                $domain
                    ->getVerificationRecordName(),
            )
            as $record
        ) {
            if (
                hash_equals(
                    $expected,
                    $record,
                )
            ) {
                return true;
            }
        }

        return false;
    }
}
