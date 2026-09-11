<?php

declare(strict_types=1);

namespace App\Mail;

interface TxtRecordResolver
{
    /**
     * @return list<string>
     */
    public function resolve(
        string $name,
    ): array;
}
