<?php

declare(strict_types=1);

namespace HeyMail\Exception;

use RuntimeException;

final class ApiException extends RuntimeException
{
    public function __construct(
        public readonly int $status,
        public readonly ?string $apiCode,
        string $message,
    ) {
        parent::__construct($message);
    }
}
