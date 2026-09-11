<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;

final readonly class DomainName
{
    public string $value;

    public function __construct(string $domain)
    {
        if (
            $domain === ''
            || trim($domain) !== $domain
            || strlen($domain) > 254
            || str_contains($domain, '@')
            || preg_match(
                '/[\x00-\x20\x7F]/',
                $domain,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Invalid sending domain.',
            );
        }

        $normalized = strtolower(
            $domain,
        );

        if (str_ends_with($normalized, '.')) {
            $normalized = substr(
                $normalized,
                0,
                -1,
            );
        }

        if (
            $normalized === ''
            || strlen($normalized) > 253
        ) {
            throw new InvalidArgumentException(
                'Invalid sending domain.',
            );
        }

        $labels = explode(
            '.',
            $normalized,
        );

        if (count($labels) < 2) {
            throw new InvalidArgumentException(
                'Sending domain must contain at least two labels.',
            );
        }

        foreach ($labels as $label) {
            if (
                preg_match(
                    '/^(?!-)[a-z0-9-]{1,63}(?<!-)$/D',
                    $label,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'Invalid sending domain label.',
                );
            }
        }

        $this->value = $normalized;
    }

    public function __toString(): string
    {
        return $this->value;
    }
}
