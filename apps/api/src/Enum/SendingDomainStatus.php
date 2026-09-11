<?php

declare(strict_types=1);

namespace App\Enum;

enum SendingDomainStatus: string
{
    case PENDING = 'pending';

    case VERIFIED = 'verified';

    case DISABLED = 'disabled';
}
