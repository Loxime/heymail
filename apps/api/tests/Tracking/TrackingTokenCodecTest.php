<?php

declare(strict_types=1);

namespace App\Tests\Tracking;

use App\Tracking\TrackingTokenCodec;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class TrackingTokenCodecTest extends TestCase
{
    private TrackingTokenCodec $codec;

    protected function setUp(): void
    {
        $this->codec = new TrackingTokenCodec(
            str_repeat('s', 64),
            'https://api.heymail.test',
        );
    }

    public function testOpenTokenIsDeterministicAndOpaque(): void
    {
        $urlA = $this->codec->openUrl(42, 7);
        $urlB = $this->codec->openUrl(42, 7);

        self::assertSame($urlA, $urlB);
        self::assertStringNotContainsString('"c":42', $urlA);

        self::assertSame(
            [
                'campaignId' => 42,
                'recipientIndex' => 7,
                'eventType' => 'opened',
                'destination' => null,
            ],
            $this->codec->decode(basename($urlA)),
        );
    }

    public function testClickTokenRoundTripsHttpsDestination(): void
    {
        $destination = 'https://example.test/path?x=1&y=2';
        $url = $this->codec->clickUrl(8, 3, $destination);
        $decoded = $this->codec->decode(basename($url));

        self::assertSame('clicked', $decoded['eventType']);
        self::assertSame($destination, $decoded['destination']);
        self::assertStringNotContainsString('example.test', $url);
    }

    public function testClickRejectsNonHttpsDestination(): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->codec->clickUrl(1, 0, 'http://example.test/');
    }

    public function testTamperedTokenFailsClosed(): void
    {
        $token = basename($this->codec->openUrl(1, 0));
        $last = substr($token, -1);
        $tampered = substr($token, 0, -1)
            . ($last === 'A' ? 'B' : 'A');

        $this->expectException(InvalidArgumentException::class);
        $this->codec->decode($tampered);
    }
}
