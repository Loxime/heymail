<?php

declare(strict_types=1);

namespace App\Tests\Query;

use App\Query\DashboardPeriod;
use DateTimeImmutable;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class DashboardPeriodTest extends TestCase
{
    public function testExplicitPeriodIsNormalizedToUtc(): void
    {
        $period =
            DashboardPeriod::fromQuery(
                '2042-01-01T01:00:00+01:00',
                '2042-01-02T01:00:00+01:00',
            );

        self::assertSame(
            '2042-01-01T00:00:00+00:00',
            $period
                ->from
                ->format(
                    DATE_ATOM,
                ),
        );

        self::assertSame(
            '2042-01-02T00:00:00+00:00',
            $period
                ->to
                ->format(
                    DATE_ATOM,
                ),
        );
    }

    public function testDefaultPeriodIsThirtyDays(): void
    {
        $period =
            DashboardPeriod::fromQuery(
                null,
                null,
                new DateTimeImmutable(
                    '2042-02-01T12:00:00+00:00',
                ),
            );

        self::assertSame(
            '2042-01-02T12:00:00+00:00',
            $period
                ->from
                ->format(
                    DATE_ATOM,
                ),
        );

        self::assertSame(
            '2042-02-01T12:00:00+00:00',
            $period
                ->to
                ->format(
                    DATE_ATOM,
                ),
        );
    }

    public function testOnlyOneBoundaryIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        DashboardPeriod::fromQuery(
            '2042-01-01T00:00:00Z',
            null,
        );
    }

    public function testReversePeriodIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        DashboardPeriod::fromQuery(
            '2042-02-01T00:00:00Z',
            '2042-01-01T00:00:00Z',
        );
    }

    public function testPeriodLongerThanNinetyDaysIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        DashboardPeriod::fromQuery(
            '2042-01-01T00:00:00Z',
            '2042-05-01T00:00:00Z',
        );
    }
}
