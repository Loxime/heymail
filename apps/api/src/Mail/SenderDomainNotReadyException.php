<?php

declare(strict_types=1);

namespace App\Mail;

use RuntimeException;

final class SenderDomainNotReadyException
    extends RuntimeException
{
}
