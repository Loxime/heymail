<?php

declare(strict_types=1);

namespace App\Mail;

use App\Entity\SendingDomain;

final readonly class SendingDomainRegistration
{
    public function __construct(
        public SendingDomain $domain,
        public bool $replayed,
    ) {
    }
}
