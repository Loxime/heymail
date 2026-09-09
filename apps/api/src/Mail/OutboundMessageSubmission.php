<?php

declare(strict_types=1);

namespace App\Mail;

use App\Enum\OutboundMessageStatus;

final readonly class OutboundMessageSubmission
{
    public function __construct(
        public int $messageId,
        public OutboundMessageStatus $status,
        public bool $replayed,
    ) {
    }
}
