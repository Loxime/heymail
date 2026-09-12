<?php

declare(strict_types=1);

namespace App\Tests\Entity;

use App\Entity\SendingDomain;
use App\Mail\DomainName;
use DateTimeImmutable;
use InvalidArgumentException;
use LogicException;
use PHPUnit\Framework\TestCase;

final class SendingDomainDkimTest extends TestCase
{
    private const string TOKEN =
        'cccccccccccccccccccccccccccccccc'
        . 'cccccccccccccccccccccccccccccccc';

    public function testVerifiedDomainCanBecomeDkimReady(): void
    {
        $domain =
            self::domain();

        $domain->markVerified();

        $at =
            new DateTimeImmutable(
                '2026-09-11T20:00:00+00:00',
            );

        $publicKey =
            base64_encode(
                'dkim-public-key',
            );

        $domain->markDkimProvisioned(
            'hm1',
            $publicKey,
            $at,
        );

        self::assertTrue(
            $domain->isDkimReady(),
        );

        self::assertSame(
            'hm1',
            $domain->getDkimSelector(),
        );

        self::assertSame(
            $publicKey,
            $domain->getDkimPublicKey(),
        );

        self::assertSame(
            $at,
            $domain->getDkimProvisionedAt(),
        );

        self::assertSame(
            'hm1._domainkey.example.com',
            $domain->getDkimRecordName(),
        );

        self::assertSame(
            sprintf(
                'v=DKIM1; k=rsa; p=%s',
                $publicKey,
            ),
            $domain->getDkimRecordValue(),
        );
    }

    public function testPendingDomainCannotBecomeDkimReady(): void
    {
        $this->expectException(
            LogicException::class,
        );

        self::domain()
            ->markDkimProvisioned(
                'hm1',
                base64_encode(
                    'key',
                ),
            );
    }

    public function testInvalidDkimMaterialIsRejected(): void
    {
        $domain =
            self::domain();

        $domain->markVerified();

        $this->expectException(
            InvalidArgumentException::class,
        );

        $domain->markDkimProvisioned(
            'INVALID SELECTOR',
            'not-base64%%',
        );
    }

    public function testDkimProvisioningIsIdempotentForSameMaterial(): void
    {
        $domain =
            self::domain();

        $domain->markVerified();

        $first =
            new DateTimeImmutable(
                '2026-09-11T20:00:00+00:00',
            );

        $second =
            new DateTimeImmutable(
                '2026-09-11T21:00:00+00:00',
            );

        $publicKey =
            base64_encode(
                'same-key',
            );

        $domain->markDkimProvisioned(
            'hm1',
            $publicKey,
            $first,
        );

        $domain->markDkimProvisioned(
            'hm1',
            $publicKey,
            $second,
        );

        self::assertSame(
            $first,
            $domain->getDkimProvisionedAt(),
        );
    }

    public function testDkimMaterialCannotBeSilentlyReplaced(): void
    {
        $domain =
            self::domain();

        $domain->markVerified();

        $domain->markDkimProvisioned(
            'hm1',
            base64_encode(
                'first-key',
            ),
        );

        $this->expectException(
            LogicException::class,
        );

        $domain->markDkimProvisioned(
            'hm1',
            base64_encode(
                'second-key',
            ),
        );
    }

    private static function domain(): SendingDomain
    {
        return new SendingDomain(
            new DomainName(
                'example.com',
            ),
            self::TOKEN,
        );
    }
}
