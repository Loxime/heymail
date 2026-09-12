<?php

declare(strict_types=1);

namespace App\Message;

use InvalidArgumentException;

final readonly class ProvisionSendingDomainDkim
{
    public function __construct(
        public int $sendingDomainId,
    ) {
        if (
            $this->sendingDomainId
            < 1
        ) {
            throw new InvalidArgumentException(
                'Sending domain ID must be positive.',
            );
        }
    }
}
