<?php

declare(strict_types=1);

namespace App\Template;

use InvalidArgumentException;

final class EmailTemplateRenderer
{
    private const string HTML_VARIABLE_PATTERN =
        '\[\[HMHTML:([a-z][a-z0-9_]{0,63})\]\]';

    /**
     * @param array<string, scalar|null> $variables
     */
    public function render(
        string $template,
        array $variables,
    ): string {
        $normalized = [];

        foreach (
            $variables
            as $name => $value
        ) {
            if (
                preg_match(
                    '/^[a-z][a-z0-9_]{0,63}$/D',
                    $name,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'Invalid template variable name.',
                );
            }

            if (
                !is_string($value)
                && !is_int($value)
                && !is_float($value)
                && !is_bool($value)
                && $value !== null
            ) {
                throw new InvalidArgumentException(
                    'Invalid template variable value.',
                );
            }

            $normalized[$name] =
                $value === null
                    ? ''
                    : (
                        is_bool($value)
                            ? (
                                $value
                                    ? 'true'
                                    : 'false'
                            )
                            : (string) $value
                    );
        }

        $pattern = sprintf(
            '/\{\{([a-z][a-z0-9_]{0,63})\}\}|%s/',
            self::HTML_VARIABLE_PATTERN,
        );

        $rendered =
            preg_replace_callback(
                $pattern,
                static function (
                    array $matches,
                ) use (
                    $normalized,
                ): string {
                    $htmlEscaped =
                        isset(
                            $matches[2],
                        )
                        && $matches[2] !== '';

                    $name =
                        $htmlEscaped
                            ? $matches[2]
                            : $matches[1];

                    if (
                        !array_key_exists(
                            $name,
                            $normalized,
                        )
                    ) {
                        throw new InvalidArgumentException(
                            sprintf(
                                'Missing template variable: %s.',
                                $name,
                            ),
                        );
                    }

                    $value =
                        $normalized[$name];

                    if (!$htmlEscaped) {
                        return $value;
                    }

                    return htmlspecialchars(
                        $value,
                        ENT_QUOTES
                        | ENT_SUBSTITUTE
                        | ENT_HTML5,
                        'UTF-8',
                    );
                },
                $template,
            );

        if (!is_string($rendered)) {
            throw new InvalidArgumentException(
                'Unable to render email template.',
            );
        }

        return $rendered;
    }

    /**
     * @return list<string>
     */
    public function variables(
        string $template,
    ): array {
        $pattern = sprintf(
            '/\{\{([a-z][a-z0-9_]{0,63})\}\}|%s/',
            self::HTML_VARIABLE_PATTERN,
        );

        preg_match_all(
            $pattern,
            $template,
            $matches,
            PREG_SET_ORDER,
        );

        $variables = [];

        foreach (
            $matches
            as $match
        ) {
            $name =
                isset(
                    $match[2],
                )
                && $match[2] !== ''
                    ? $match[2]
                    : (
                        $match[1]
                        ?? null
                    );

            if (
                is_string($name)
                && $name !== ''
            ) {
                $variables[] =
                    $name;
            }
        }

        $variables =
            array_values(
                array_unique(
                    $variables,
                ),
            );

        sort(
            $variables,
            SORT_STRING,
        );

        return $variables;
    }
}
