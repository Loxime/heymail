<?php

declare(strict_types=1);

namespace App\Tests\Template;

use App\Template\VisualEmailDocumentRenderer;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class VisualEmailDocumentRendererTest extends TestCase
{
    public function testRendersEscapedVisualDocument(): void
    {
        $renderer =
            new VisualEmailDocumentRenderer();

        $html =
            $renderer->render([
                'version' => 1,
                'blocks' => [
                    [
                        'id' => 'intro',
                        'type' => 'text',
                        'text'
                            => '<b>Hello</b> {{first_name}}',
                        'align' => 'left',
                    ],
                    [
                        'id' => 'cta',
                        'type' => 'button',
                        'label'
                            => 'Open {{first_name}}',
                        'url'
                            => 'https://example.test/welcome',
                        'align' => 'center',
                    ],
                    [
                        'id' => 'image',
                        'type' => 'image',
                        'url'
                            => 'https://example.test/image.png',
                        'alt' => 'Welcome',
                        'align' => 'center',
                    ],
                    [
                        'id' => 'columns',
                        'type' => 'columns',
                        'columns' => [
                            [
                                'text' => 'Left',
                                'align' => 'left',
                            ],
                            [
                                'text' => 'Right',
                                'align' => 'right',
                            ],
                        ],
                    ],
                ],
            ]);

        self::assertStringContainsString(
            '&lt;b&gt;Hello&lt;/b&gt; [[HMHTML:first_name]]',
            $html,
        );

        self::assertStringContainsString(
            'href="https://example.test/welcome"',
            $html,
        );

        self::assertStringContainsString(
            'src="https://example.test/image.png"',
            $html,
        );

        self::assertStringNotContainsString(
            '<b>Hello</b>',
            $html,
        );
    }

    public function testImageAltVariableIsEscapedInAttributeContext(): void
    {
        $visual =
            new VisualEmailDocumentRenderer();

        $html =
            $visual->render([
                'version' => 1,
                'blocks' => [
                    [
                        'id' => 'image',
                        'type' => 'image',
                        'url'
                            => 'https://example.test/image.png',
                        'alt'
                            => 'Portrait {{first_name}}',
                        'align' => 'center',
                    ],
                ],
            ]);

        self::assertStringContainsString(
            'alt="Portrait [[HMHTML:first_name]]"',
            $html,
        );

        $rendered =
            (
                new \App\Template\EmailTemplateRenderer()
            )->render(
                $html,
                [
                    'first_name'
                        => '" onerror="alert(1)',
                ],
            );

        self::assertStringContainsString(
            'alt="Portrait &quot; onerror=&quot;alert(1)"',
            $rendered,
        );

        self::assertStringNotContainsString(
            'alt="Portrait " onerror="alert(1)"',
            $rendered,
        );
    }

    public function testRejectsInsecureUrl(): void
    {
        $renderer =
            new VisualEmailDocumentRenderer();

        $this->expectException(
            InvalidArgumentException::class,
        );

        $renderer->normalize([
            'version' => 1,
            'blocks' => [
                [
                    'id' => 'bad',
                    'type' => 'image',
                    'url'
                        => 'http://example.test/image.png',
                    'alt' => 'Bad',
                    'align' => 'left',
                ],
            ],
        ]);
    }
}
