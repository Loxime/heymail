<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Enum\OutboundMessageEventType;
use App\Mail\DsnSpoolEvent;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class DsnSpoolEventTest extends TestCase
{
    public function testAcceptsStrictDeliveryEvent(): void
    {
        $event = DsnSpoolEvent::fromJson(
            self::json(),
        );

        self::assertSame(
            42,
            $event->messageId,
        );

        self::assertSame(
            OutboundMessageEventType::BOUNCED,
            $event->type,
        );

        self::assertSame(
            '5.1.1',
            $event->smtpStatus,
        );

        self::assertSame(
            '0e474a9f0abf9c7798fb60bdf12eb12f00118869e9deb39703507a1f76f5c003',
            $event->sourceEventId,
        );
    }

    public function testRejectsStatusTypeMismatch(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        DsnSpoolEvent::fromJson(
            self::json([
                'type' => 'tempfail',
            ]),
        );
    }

    public function testRejectsRawAddressInDiagnostic(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        DsnSpoolEvent::fromJson(
            self::json([
                'detail'
                    => '550 user@example.test rejected',
            ]),
        );
    }

    public function testRejectsForgedSourceIdentifier(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        DsnSpoolEvent::fromJson(
            self::json([
                'sourceEventId'
                    => str_repeat('f', 64),
            ]),
        );
    }

    /**
     * @param array<string, mixed> $override
     */
    private static function json(
        array $override = [],
    ): string {
        return json_encode(
            array_replace(
                [
                    'messageId' => 42,
                    'recipientHash'
                        => str_repeat('a', 64),
                    'type' => 'bounced',
                    'smtpStatus' => '5.1.1',
                    'detail'
                        => 'smtp; 550 5.1.1 User unknown',
                    'sourceEventId'
                        => '0e474a9f0abf9c7798fb60bdf12eb12f00118869e9deb39703507a1f76f5c003',
                ],
                $override,
            ),
            JSON_THROW_ON_ERROR,
        );
    }
}
