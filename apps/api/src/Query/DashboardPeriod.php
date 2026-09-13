<?php

declare(strict_types=1);

namespace App\Query;

use DateTimeImmutable;
use DateTimeZone;
use InvalidArgumentException;
use Throwable;

final readonly class DashboardPeriod
{
    private const int MAX_SECONDS =
        90 * 86400;

    public function __construct(
        public DateTimeImmutable $from,
        public DateTimeImmutable $to,
    ) {
        if ($this->from >= $this->to) {
            throw new InvalidArgumentException(
                'Dashboard period start must be before end.',
            );
        }

        if (
            $this->to->getTimestamp()
            - $this->from->getTimestamp()
            > self::MAX_SECONDS
        ) {
            throw new InvalidArgumentException(
                'Dashboard period cannot exceed 90 days.',
            );
        }
    }

    public static function fromQuery(
        ?string $from,
        ?string $to,
        ?DateTimeImmutable $now = null,
    ): self {
        if (
            $from === null
            && $to === null
        ) {
            $end =
                ($now ?? self::now())
                    ->setTimezone(
                        self::utc(),
                    );

            return new self(
                from: $end->modify(
                    '-30 days',
                ),
                to: $end,
            );
        }

        if (
            $from === null
            || $to === null
        ) {
            throw new InvalidArgumentException(
                'Dashboard from and to must be supplied together.',
            );
        }

        return new self(
            from: self::parse(
                $from,
            ),
            to: self::parse(
                $to,
            ),
        );
    }

    private static function parse(
        string $value,
    ): DateTimeImmutable {
        if (
            strlen($value) > 64
            || preg_match(
                '/^\d{4}-\d{2}-\d{2}T'
                . '\d{2}:\d{2}:\d{2}'
                . '(?:\.\d{1,6})?'
                . '(?:Z|[+-]\d{2}:\d{2})$/D',
                $value,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Dashboard dates must be RFC 3339 timestamps.',
            );
        }

        try {
            return (
                new DateTimeImmutable(
                    $value,
                )
            )->setTimezone(
                self::utc(),
            );
        } catch (Throwable $exception) {
            throw new InvalidArgumentException(
                'Invalid dashboard date.',
                0,
                $exception,
            );
        }
    }

    private static function now(): DateTimeImmutable
    {
        return new DateTimeImmutable(
            'now',
            self::utc(),
        );
    }

    private static function utc(): DateTimeZone
    {
        return new DateTimeZone(
            'UTC',
        );
    }
}
