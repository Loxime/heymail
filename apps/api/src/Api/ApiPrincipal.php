<?php

declare(strict_types=1);

namespace App\Api;

use InvalidArgumentException;

final readonly class ApiPrincipal
{
    public function __construct(
        public string $keyFingerprint,
        public int $workspaceId,
    ) {
        if (
            preg_match(
                '/^[a-f0-9]{64}$/D',
                $this->keyFingerprint,
            ) !== 1
            || $this->workspaceId < 1
        ) {
            throw new InvalidArgumentException(
                'Invalid API principal.',
            );
        }
    }
}
