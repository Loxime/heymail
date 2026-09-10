<?php

declare(strict_types=1);

namespace App\Message;

use InvalidArgumentException;

final readonly class SendOutboundEmail
{
    public function __construct(
        public int $outboundMessageId,
    ) {
        if ($this->outboundMessageId < 1) {
            throw new InvalidArgumentException(
                'Outbound message ID must be positive.',
            );
        }
    }
}
