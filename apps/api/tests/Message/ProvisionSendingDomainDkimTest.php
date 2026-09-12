<?php

declare(strict_types=1);

namespace App\Tests\Message;

use App\Message\ProvisionSendingDomainDkim;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class ProvisionSendingDomainDkimTest extends TestCase
{
    public function testMessageContainsOnlySendingDomainId(): void
    {
        $message =
            new ProvisionSendingDomainDkim(
                42,
            );

        self::assertSame(
            42,
            $message->sendingDomainId,
        );

        self::assertSame(
            [
                'sendingDomainId',
            ],
            array_keys(
                get_object_vars(
                    $message,
                ),
            ),
        );
    }

    public function testInvalidIdIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new ProvisionSendingDomainDkim(
            0,
        );
    }
}
