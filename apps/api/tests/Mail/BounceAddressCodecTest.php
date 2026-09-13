<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\BounceAddressCodec;
use PHPUnit\Framework\TestCase;

final class BounceAddressCodecTest extends TestCase
{
    public function testSenderContainsAuthenticatedToken(): void
    {
        $keyFile = tempnam(
            sys_get_temp_dir(),
            'heymail-bounce-',
        );

        self::assertIsString(
            $keyFile,
        );

        file_put_contents(
            $keyFile,
            str_repeat(
                'a',
                64,
            ),
        );

        try {
            $codec =
                new BounceAddressCodec(
                    'bounce.example.com',
                    $keyFile,
                );

            $sender =
                $codec->senderFor(
                    42,
                );

            self::assertMatchesRegularExpression(
                '/^bounce\+42\+'
                . '([a-f0-9]{32})'
                . '@bounce\.example\.com$/D',
                $sender,
            );

            preg_match(
                '/^bounce\+42\+'
                . '([a-f0-9]{32})@/',
                $sender,
                $matches,
            );

            self::assertTrue(
                $codec->validates(
                    42,
                    $matches[1],
                ),
            );

            self::assertFalse(
                $codec->validates(
                    43,
                    $matches[1],
                ),
            );
        } finally {
            @unlink(
                $keyFile,
            );
        }
    }
}
