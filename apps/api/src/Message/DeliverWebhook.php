<?php

declare(strict_types=1);

namespace App\Message;

use InvalidArgumentException;

final readonly class DeliverWebhook
{
    public function __construct(
        public int $webhookDeliveryId,
    ) {
        if ($this->webhookDeliveryId < 1) {
            throw new InvalidArgumentException(
                'Webhook delivery ID must be positive.',
            );
        }
    }
}
