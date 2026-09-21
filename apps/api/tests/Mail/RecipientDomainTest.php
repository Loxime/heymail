<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\RecipientDomain;
use InvalidArgumentException;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class RecipientDomainTest extends TestCase
{
    public function testExtractsNormalizedDomain(): void
    {
        self::assertSame(
            'sub.example.test',
            RecipientDomain::fromEmail(
                'Person@Sub.Example.Test',
            ),
        );
    }

    #[DataProvider('invalidEmails')]
    public function testRejectsInvalidEmailDomain(
        string $email,
    ): void {
        $this->expectException(
            InvalidArgumentException::class,
        );

        RecipientDomain::fromEmail(
            $email,
        );
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function invalidEmails(): iterable
    {
        yield 'missing at' => [
            'recipient.example.test',
        ];

        yield 'missing domain' => [
            'recipient@',
        ];

        yield 'empty label' => [
            'recipient@example..test',
        ];

        yield 'leading hyphen' => [
            'recipient@-example.test',
        ];
    }
}
