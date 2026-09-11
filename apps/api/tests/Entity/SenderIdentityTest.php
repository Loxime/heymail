<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\SenderIdentity;
use App\Entity\SendingDomain;
use App\Mail\DomainName;
use App\Mail\SenderEmailAddress;
use DateTimeImmutable;
use LogicException;
use PHPUnit\Framework\TestCase;

final class SenderIdentityTest extends TestCase
{
    private const string TOKEN =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        . 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

    public function testVerifiedDomainCanCreateSender(): void
    {
        $domain =
            self::verifiedDomain();

        $createdAt =
            new DateTimeImmutable(
                '2026-09-11T18:00:00+00:00',
            );

        $sender =
            new SenderIdentity(
                $domain,
                new SenderEmailAddress(
                    'Sender@Example.COM',
                ),
                $createdAt,
            );

        self::assertSame(
            'sender@example.com',
            $sender->getEmail(),
        );

        self::assertSame(
            $domain,
            $sender->getSendingDomain(),
        );

        self::assertSame(
            $createdAt,
            $sender->getCreatedAt(),
        );

        self::assertTrue(
            $sender->isAuthorized(),
        );
    }

    public function testPendingDomainCannotCreateSender(): void
    {
        $domain =
            new SendingDomain(
                new DomainName(
                    'example.com',
                ),
                self::TOKEN,
            );

        $this->expectException(
            LogicException::class,
        );

        new SenderIdentity(
            $domain,
            new SenderEmailAddress(
                'sender@example.com',
            ),
        );
    }

    public function testSenderMustBelongToItsDomain(): void
    {
        $domain =
            self::verifiedDomain();

        $this->expectException(
            LogicException::class,
        );

        new SenderIdentity(
            $domain,
            new SenderEmailAddress(
                'sender@other.example',
            ),
        );
    }

    private static function verifiedDomain(): SendingDomain
    {
        $domain =
            new SendingDomain(
                new DomainName(
                    'example.com',
                ),
                self::TOKEN,
            );

        $domain->markVerified(
            new DateTimeImmutable(
                '2026-09-11T17:00:00+00:00',
            ),
        );

        return $domain;
    }
}
