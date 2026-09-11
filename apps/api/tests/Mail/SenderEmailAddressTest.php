<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\SenderEmailAddress;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class SenderEmailAddressTest extends TestCase
{
    public function testSenderEmailIsCanonicalized(): void
    {
        $sender =
            new SenderEmailAddress(
                'Sender@Example.COM',
            );

        self::assertSame(
            'sender@example.com',
            $sender->value,
        );

        self::assertSame(
            'example.com',
            $sender->domain,
        );
    }

    public function testSenderEmailRequiresDnsDomain(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new SenderEmailAddress(
            'sender@localhost',
        );
    }
}
