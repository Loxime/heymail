<?php

declare(strict_types=1);

namespace App\Enum;

enum WebhookDeliveryStatus: string
{
    case PENDING = 'pending';
    case SUCCEEDED = 'succeeded';
    case DEAD = 'dead';
}
