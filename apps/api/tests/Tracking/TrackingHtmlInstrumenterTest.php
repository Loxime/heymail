<?php

declare(strict_types=1);

namespace App\Tests\Tracking;

use App\Tracking\TrackingHtmlInstrumenter;
use App\Tracking\TrackingTokenCodec;
use PHPUnit\Framework\TestCase;

final class TrackingHtmlInstrumenterTest extends TestCase
{
    public function testInstrumentsHttpsLinksAndOpenPixel(): void
    {
        $codec = new TrackingTokenCodec(
            str_repeat('k', 64),
            'https://api.heymail.test',
        );
        $instrumenter = new TrackingHtmlInstrumenter($codec);

        $html = $instrumenter->instrument(
            '<p><a href="https://example.test/path?x=1&amp;y=2">Web</a> <a href="mailto:user@example.test">Mail</a></p>',
            5,
            2,
        );

        self::assertStringContainsString(
            'https://api.heymail.test/track/click/t1.',
            $html,
        );
        self::assertStringContainsString(
            'https://api.heymail.test/track/open/t1.',
            $html,
        );
        self::assertStringContainsString(
            'href="mailto:user@example.test"',
            $html,
        );
        self::assertStringNotContainsString(
            'href="https://example.test/path',
            $html,
        );
    }
}
