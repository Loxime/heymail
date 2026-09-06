<?php

declare(strict_types=1);

namespace App\Enum;

enum OutboundMessageStatus: string
{
    case QUEUED = 'queued';
    case READY_FOR_SUBMISSION = 'ready_for_submission';
}
