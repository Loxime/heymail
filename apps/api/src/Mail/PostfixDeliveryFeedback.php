<?php

declare(strict_types=1);

namespace App\Mail;

use App\Enum\OutboundMessageEventType;

final readonly class PostfixDeliveryFeedback
{
    public function __construct(
        public int $outboundMessageId,
        public string $recipient,
        public OutboundMessageEventType $type,
        public string $smtpStatus,
        public string $detail,
        public string $sourceEventId,
    ) {
    }
}
