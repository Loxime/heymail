<?php

declare(strict_types=1);

namespace App\Tests\Message;

use App\Message\SendOutboundEmail;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class SendOutboundEmailTest extends TestCase
{
    public function testMessageContainsOnlyOutboundMessageId(): void
    {
        $message = new SendOutboundEmail(42);

        self::assertSame(
            42,
            $message->outboundMessageId,
        );

        self::assertSame(
            ['outboundMessageId'],
            array_keys(get_object_vars($message)),
        );
    }

    public function testInvalidIdIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new SendOutboundEmail(0);
    }
}
