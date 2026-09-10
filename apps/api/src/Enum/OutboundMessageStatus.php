<?php

declare(strict_types=1);

namespace App\Enum;

enum OutboundMessageStatus: string
{
    case QUEUED = 'queued';

    case READY_FOR_SUBMISSION = 'ready_for_submission';

    /**
     * A durable SMTP submission attempt has started.
     *
     * Once this state has been persisted, the message must never be
     * automatically submitted again. A worker crash may have happened
     * after the SMTP server accepted the message.
     */
    case SUBMITTING = 'submitting';

    /**
     * The previous SMTP attempt has an indeterminate outcome.
     *
     * Automatic retries are forbidden from this state. A later
     * reconciliation mechanism must determine the definitive outcome.
     */
    case SUBMISSION_UNCERTAIN = 'submission_uncertain';

    case SUBMITTED = 'submitted';
}
