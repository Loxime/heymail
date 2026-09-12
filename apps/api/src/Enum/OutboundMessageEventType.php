<?php

declare(strict_types=1);

namespace App\Enum;

enum OutboundMessageEventType: string
{
    case QUEUED = 'queued';
    case READY_FOR_SUBMISSION = 'ready_for_submission';
    case SUBMITTING = 'submitting';
    case SUBMISSION_UNCERTAIN = 'submission_uncertain';
    case SUBMITTED = 'submitted';

    case TEMPFAIL = 'tempfail';
    case DELIVERED = 'delivered';
    case BOUNCED = 'bounced';

    public static function fromMessageStatus(
        OutboundMessageStatus $status,
    ): self {
        return self::from(
            $status->value,
        );
    }

    public function isDelivery(): bool
    {
        return match ($this) {
            self::TEMPFAIL,
            self::DELIVERED,
            self::BOUNCED => true,

            default => false,
        };
    }
}
