<?php

declare(strict_types=1);

namespace App\Mail;

interface OutboundMessageSubmitter
{
    public function submit(
        int $outboundMessageId,
        OutboundEmailPayload $payload,
    ): void;
}
