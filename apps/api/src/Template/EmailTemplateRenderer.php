<?php

declare(strict_types=1);

namespace App\Template;

use InvalidArgumentException;

final class EmailTemplateRenderer
{
    /**
     * @param array<string, scalar|null> $variables
     */
    public function render(string $template, array $variables): string
    {
        $normalized = [];

        foreach ($variables as $name => $value) {
            if (preg_match('/^[a-z][a-z0-9_]{0,63}$/D', $name) !== 1) {
                throw new InvalidArgumentException('Invalid template variable name.');
            }

            if (!is_string($value) && !is_int($value) && !is_float($value) && !is_bool($value) && $value !== null) {
                throw new InvalidArgumentException('Invalid template variable value.');
            }

            $normalized[$name] = $value === null
                ? ''
                : (is_bool($value) ? ($value ? 'true' : 'false') : (string) $value);
        }

        $rendered = preg_replace_callback(
            '/\{\{([a-z][a-z0-9_]{0,63})\}\}/',
            static function (array $matches) use ($normalized): string {
                $name = $matches[1];

                if (!array_key_exists($name, $normalized)) {
                    throw new InvalidArgumentException(sprintf(
                        'Missing template variable: %s.',
                        $name,
                    ));
                }

                return $normalized[$name];
            },
            $template,
        );

        if (!is_string($rendered)) {
            throw new InvalidArgumentException('Unable to render email template.');
        }

        return $rendered;
    }

    /**
     * @return list<string>
     */
    public function variables(string $template): array
    {
        preg_match_all(
            '/\{\{([a-z][a-z0-9_]{0,63})\}\}/',
            $template,
            $matches,
        );

        $variables = array_values(array_unique(array_filter(
            $matches[1] ?? [],
            is_string(...),
        )));

        sort($variables, SORT_STRING);

        return $variables;
    }
}
