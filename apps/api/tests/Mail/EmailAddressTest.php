<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\EmailAddress;
use InvalidArgumentException;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class EmailAddressTest extends TestCase
{
    public function testValidAddressRoundTrip(): void
    {
        $address = new EmailAddress(
            email: 'sender@heymail.test',
            name: 'HeyMail Sender',
        );

        self::assertSame(
            [
                'email' => 'sender@heymail.test',
                'name' => 'HeyMail Sender',
            ],
            $address->toArray(),
        );

        self::assertEquals(
            $address,
            EmailAddress::fromArray(
                $address->toArray(),
            ),
        );
    }

    #[DataProvider('invalidEmailProvider')]
    public function testInvalidEmailIsRejected(
        string $email,
    ): void {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new EmailAddress($email);
    }

    /**
     * @return iterable<string, array{string}>
     */
    public static function invalidEmailProvider(): iterable
    {
        yield 'empty' => [''];
        yield 'invalid' => ['not-an-email'];
        yield 'leading space' => [' a@example.test'];
        yield 'header injection' => [
            "a@example.test\r\nBcc: attacker@example.test",
        ];
    }

    public function testHeaderInjectionInNameIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new EmailAddress(
            'sender@heymail.test',
            "Sender\r\nBcc: attacker@example.test",
        );
    }
}
