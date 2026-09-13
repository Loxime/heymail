<?php

declare(strict_types=1);

namespace App\Tests\Query;

use App\Query\MessageCursorCodec;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class MessageCursorCodecTest extends TestCase
{
    public function testRoundTrip(): void
    {
        $codec =
            new MessageCursorCodec(
                'test-secret-that-is-not-empty',
            );

        $cursor =
            $codec->encode(
                12345,
            );

        self::assertSame(
            12345,
            $codec->decode(
                $cursor,
            ),
        );
    }

    public function testTamperingIsRejected(): void
    {
        $codec =
            new MessageCursorCodec(
                'test-secret-that-is-not-empty',
            );

        $cursor =
            $codec->encode(
                12345,
            );

        $cursor[0] =
            $cursor[0] === 'A'
                ? 'B'
                : 'A';

        $this->expectException(
            InvalidArgumentException::class,
        );

        $codec->decode(
            $cursor,
        );
    }

    public function testWrongSecretIsRejected(): void
    {
        $writer =
            new MessageCursorCodec(
                'writer-secret',
            );

        $reader =
            new MessageCursorCodec(
                'reader-secret',
            );

        $cursor =
            $writer->encode(
                42,
            );

        $this->expectException(
            InvalidArgumentException::class,
        );

        $reader->decode(
            $cursor,
        );
    }

    public function testMalformedCursorIsRejected(): void
    {
        $codec =
            new MessageCursorCodec(
                'test-secret',
            );

        $this->expectException(
            InvalidArgumentException::class,
        );

        $codec->decode(
            'definitely-not-a-valid-cursor',
        );
    }
}
