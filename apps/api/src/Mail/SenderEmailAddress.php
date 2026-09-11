<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;

final readonly class SenderEmailAddress
{
    public string $value;
    public string $domain;

    public function __construct(
        string $email,
    ) {
        /*
         * Reuse the public email-address validation rules first.
         */
        new EmailAddress(
            $email,
        );

        $separator =
            strrpos(
                $email,
                '@',
            );

        if (
            $separator === false
            || $separator < 1
            || $separator
                === strlen($email) - 1
        ) {
            throw new InvalidArgumentException(
                'Invalid sender email address.',
            );
        }

        $localPart =
            substr(
                $email,
                0,
                $separator,
            );

        $domain =
            new DomainName(
                substr(
                    $email,
                    $separator + 1,
                ),
            );

        /*
         * HeyMail sender identities are canonicalized case-insensitively.
         *
         * This deliberately prevents duplicate sender identities such as:
         *
         * Sender@Example.com
         * sender@example.com
         */
        $this->value =
            strtolower(
                $localPart,
            )
            . '@'
            . $domain->value;

        $this->domain =
            $domain->value;
    }

    public function __toString(): string
    {
        return $this->value;
    }
}
