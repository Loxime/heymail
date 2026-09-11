<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\DomainName;
use InvalidArgumentException;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class DomainNameTest extends TestCase
{
    public function testDomainIsCanonicalized(): void
    {
        $domain =
            new DomainName(
                'MAIL.Example.COM.',
            );

        self::assertSame(
            'mail.example.com',
            $domain->value,
        );
    }

    #[DataProvider('invalidDomains')]
    public function testInvalidDomainsAreRejected(
        string $domain,
    ): void {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new DomainName(
            $domain,
        );
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function invalidDomains(): iterable
    {
        yield 'empty' => [''];

        yield 'single label' => [
            'localhost',
        ];

        yield 'URL' => [
            'https://example.com',
        ];

        yield 'email' => [
            'user@example.com',
        ];

        yield 'double dot' => [
            'example..com',
        ];

        yield 'leading hyphen' => [
            '-example.com',
        ];

        yield 'trailing hyphen' => [
            'example-.com',
        ];

        yield 'whitespace' => [
            ' example.com',
        ];
    }
}
