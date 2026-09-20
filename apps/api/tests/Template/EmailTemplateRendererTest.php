<?php

declare(strict_types=1);

namespace App\Tests\Template;

use App\Template\EmailTemplateRenderer;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class EmailTemplateRendererTest extends TestCase
{
    public function testRendersVariablesDeterministically(): void
    {
        $renderer = new EmailTemplateRenderer();

        self::assertSame(
            'Hello Ada, order 42.',
            $renderer->render(
                'Hello {{first_name}}, order {{order_id}}.',
                [
                    'first_name' => 'Ada',
                    'order_id' => 42,
                ],
            ),
        );
    }

    public function testMissingVariableFailsClosed(): void
    {
        $renderer = new EmailTemplateRenderer();

        $this->expectException(InvalidArgumentException::class);

        $renderer->render(
            'Hello {{first_name}}.',
            [],
        );
    }

    public function testExtractsSortedUniqueVariables(): void
    {
        $renderer = new EmailTemplateRenderer();

        self::assertSame(
            ['first_name', 'order_id'],
            $renderer->variables(
                '{{order_id}} {{first_name}} {{order_id}}',
            ),
        );
    }
}
