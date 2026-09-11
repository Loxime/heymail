<?php

declare(strict_types=1);

namespace App\Mail;

use App\Entity\SenderIdentity;

final readonly class SenderIdentityRegistration
{
    public function __construct(
        public SenderIdentity $sender,
        public bool $replayed,
    ) {
    }
}
