<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;

final class RecipientDomain
{
    private const string PATTERN =
        '/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D';

    public static function fromEmail(
        string $email,
    ): string {
        $normalized =
            strtolower(
                trim(
                    $email,
                ),
            );

        $separator =
            strrpos(
                $normalized,
                '@',
            );

        if (
            $separator === false
            || $separator === 0
            || $separator
                === strlen($normalized) - 1
        ) {
            throw new InvalidArgumentException(
                'Unable to derive recipient domain.',
            );
        }

        $domain =
            substr(
                $normalized,
                $separator + 1,
            );

        if (
            strlen($domain) > 253
            || preg_match(
                self::PATTERN,
                $domain,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid recipient domain.',
            );
        }

        return $domain;
    }
}
