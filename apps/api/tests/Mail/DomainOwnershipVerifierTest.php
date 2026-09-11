<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Entity\SendingDomain;
use App\Mail\DomainName;
use App\Mail\DomainOwnershipVerifier;
use App\Mail\TxtRecordResolver;
use PHPUnit\Framework\TestCase;

final class DomainOwnershipVerifierTest extends TestCase
{
    private const string TOKEN =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        . 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    public function testMatchingTxtRecordVerifiesOwnership(): void
    {
        $domain =
            self::domain();

        $verifier =
            new DomainOwnershipVerifier(
                new FixedTxtRecordResolver(
                    [
                        $domain
                            ->getVerificationRecordValue(),
                    ],
                ),
            );

        self::assertTrue(
            $verifier->verify(
                $domain,
            ),
        );
    }

    public function testWrongTxtRecordDoesNotVerifyOwnership(): void
    {
        $verifier =
            new DomainOwnershipVerifier(
                new FixedTxtRecordResolver(
                    [
                        'heymail-verification=wrong',
                    ],
                ),
            );

        self::assertFalse(
            $verifier->verify(
                self::domain(),
            ),
        );
    }

    public function testMatchingRecordCanCoexistWithOtherTxtRecords(): void
    {
        $domain =
            self::domain();

        $verifier =
            new DomainOwnershipVerifier(
                new FixedTxtRecordResolver(
                    [
                        'v=spf1 -all',
                        'google-site-verification=test',
                        $domain
                            ->getVerificationRecordValue(),
                    ],
                ),
            );

        self::assertTrue(
            $verifier->verify(
                $domain,
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

/**
 * @internal
 */
final readonly class FixedTxtRecordResolver
    implements TxtRecordResolver
{
    /**
     * @param list<string> $records
     */
    public function __construct(
        private array $records,
    ) {
    }

    public function resolve(
        string $name,
    ): array {
        if (
            $name
            !== '_heymail-verification.example.com'
        ) {
            return [];
        }

        return $this->records;
    }
}
