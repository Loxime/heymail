<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\SendingDomain;
use App\Enum\SendingDomainStatus;
use App\Mail\DomainName;
use DateTimeImmutable;
use LogicException;
use PHPUnit\Framework\TestCase;

final class SendingDomainTest extends TestCase
{
    private const string TOKEN =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        . 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    public function testPendingDomainExposesDnsChallenge(): void
    {
        $domain =
            new SendingDomain(
                new DomainName(
                    'Example.COM',
                ),
                self::TOKEN,
            );

        self::assertSame(
            'example.com',
            $domain->getDomain(),
        );

        self::assertSame(
            SendingDomainStatus::PENDING,
            $domain->getStatus(),
        );

        self::assertSame(
            '_heymail-verification.example.com',
            $domain->getVerificationRecordName(),
        );

        self::assertSame(
            'heymail-verification='
                . self::TOKEN,
            $domain->getVerificationRecordValue(),
        );

        self::assertNull(
            $domain->getVerifiedAt(),
        );

        self::assertNull(
            $domain->getDisabledAt(),
        );
    }

    public function testPendingDomainCanBeVerified(): void
    {
        $verifiedAt =
            new DateTimeImmutable(
                '2026-09-10T20:00:00+00:00',
            );

        $domain =
            new SendingDomain(
                new DomainName(
                    'example.com',
                ),
                self::TOKEN,
            );

        $domain->markVerified(
            $verifiedAt,
        );

        self::assertSame(
            SendingDomainStatus::VERIFIED,
            $domain->getStatus(),
        );

        self::assertSame(
            $verifiedAt,
            $domain->getVerifiedAt(),
        );
    }

    public function testVerificationIsIdempotent(): void
    {
        $first =
            new DateTimeImmutable(
                '2026-09-10T20:00:00+00:00',
            );

        $second =
            new DateTimeImmutable(
                '2026-09-10T21:00:00+00:00',
            );

        $domain =
            new SendingDomain(
                new DomainName(
                    'example.com',
                ),
                self::TOKEN,
            );

        $domain->markVerified($first);
        $domain->markVerified($second);

        self::assertSame(
            $first,
            $domain->getVerifiedAt(),
        );
    }

    public function testDisabledDomainCannotBecomeVerified(): void
    {
        $domain =
            new SendingDomain(
                new DomainName(
                    'example.com',
                ),
                self::TOKEN,
            );

        $domain->disable();

        $this->expectException(
            LogicException::class,
        );

        $domain->markVerified();
    }
}
