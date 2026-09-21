<?php

declare(strict_types=1);

namespace App\Template;

use InvalidArgumentException;

final class VisualEmailDocumentRenderer
{
    private const int MAX_BLOCKS = 100;
    private const int MAX_TEXT_BYTES = 10000;
    private const int MAX_URL_BYTES = 2048;
    private const string INTERNAL_MARKER = '[[HMHTML:';

    /**
     * @return array{
     *     version:1,
     *     blocks:list<array<string,mixed>>
     * }
     */
    public function normalize(
        mixed $document,
    ): array {
        if (
            !is_array($document)
            || array_is_list($document)
            || !self::keysAre(
                $document,
                [
                    'version',
                    'blocks',
                ],
            )
            || ($document['version'] ?? null) !== 1
            || !is_array(
                $document['blocks']
                ?? null,
            )
            || !array_is_list(
                $document['blocks'],
            )
            || $document['blocks'] === []
            || count(
                $document['blocks'],
            ) > self::MAX_BLOCKS
        ) {
            throw new InvalidArgumentException(
                'Visual email document is invalid.',
            );
        }

        $ids = [];
        $blocks = [];

        foreach (
            $document['blocks']
            as $block
        ) {
            $blocks[] =
                $this->normalizeBlock(
                    $block,
                    $ids,
                );
        }

        return [
            'version' => 1,
            'blocks' => $blocks,
        ];
    }

    /**
     * @param array<string,mixed> $document
     */
    public function render(
        array $document,
    ): string {
        $document =
            $this->normalize(
                $document,
            );

        $rows = '';

        foreach (
            $document['blocks']
            as $block
        ) {
            $rows .=
                $this->renderBlock(
                    $block,
                );
        }

        return sprintf(
            '<div style="margin:0;background:#f4f7f9;padding:24px 12px"><table role="presentation" width="100%%" cellspacing="0" cellpadding="0" border="0" style="width:100%%;max-width:640px;margin:0 auto;background:#ffffff;border-collapse:collapse"><tbody>%s</tbody></table></div>',
            $rows,
        );
    }

    /**
     * @param array<string,true> $ids
     * @return array<string,mixed>
     */
    private function normalizeBlock(
        mixed $block,
        array &$ids,
    ): array {
        if (
            !is_array($block)
            || array_is_list($block)
            || !is_string(
                $block['id']
                ?? null,
            )
            || preg_match(
                '/^[A-Za-z0-9_-]{1,64}$/D',
                $block['id'],
            ) !== 1
            || isset(
                $ids[
                    $block['id']
                ],
            )
            || !is_string(
                $block['type']
                ?? null,
            )
        ) {
            throw new InvalidArgumentException(
                'Visual email block is invalid.',
            );
        }

        $ids[$block['id']] = true;

        return match (
            $block['type']
        ) {
            'text'
                => $this->textBlock(
                    $block,
                ),
            'image'
                => $this->imageBlock(
                    $block,
                ),
            'button'
                => $this->buttonBlock(
                    $block,
                ),
            'columns'
                => $this->columnsBlock(
                    $block,
                ),
            default
                => throw new InvalidArgumentException(
                    'Unsupported visual email block type.',
                ),
        };
    }

    /**
     * @param array<string,mixed> $block
     * @return array<string,mixed>
     */
    private function textBlock(
        array $block,
    ): array {
        if (
            !self::keysAre(
                $block,
                [
                    'id',
                    'type',
                    'text',
                    'align',
                ],
            )
            || !self::validText(
                $block['text']
                ?? null,
            )
        ) {
            throw new InvalidArgumentException(
                'Visual text block is invalid.',
            );
        }

        return [
            'id' => $block['id'],
            'type' => 'text',
            'text' => $block['text'],
            'align'
                => self::alignment(
                    $block['align']
                    ?? null,
                ),
        ];
    }

    /**
     * @param array<string,mixed> $block
     * @return array<string,mixed>
     */
    private function imageBlock(
        array $block,
    ): array {
        if (
            !self::keysAre(
                $block,
                [
                    'id',
                    'type',
                    'url',
                    'alt',
                    'align',
                ],
            )
            || !is_string(
                $block['alt']
                ?? null,
            )
            || strlen(
                $block['alt'],
            ) > 255
            || str_contains(
                $block['alt'],
                "\0",
            )
        ) {
            throw new InvalidArgumentException(
                'Visual image block is invalid.',
            );
        }

        return [
            'id' => $block['id'],
            'type' => 'image',
            'url'
                => self::httpsUrl(
                    $block['url']
                    ?? null,
                ),
            'alt' => $block['alt'],
            'align'
                => self::alignment(
                    $block['align']
                    ?? null,
                ),
        ];
    }

    /**
     * @param array<string,mixed> $block
     * @return array<string,mixed>
     */
    private function buttonBlock(
        array $block,
    ): array {
        if (
            !self::keysAre(
                $block,
                [
                    'id',
                    'type',
                    'label',
                    'url',
                    'align',
                ],
            )
            || !is_string(
                $block['label']
                ?? null,
            )
            || trim(
                $block['label'],
            ) === ''
            || strlen(
                $block['label'],
            ) > 200
            || str_contains(
                $block['label'],
                "\0",
            )
            || str_contains(
                $block['label'],
                self::INTERNAL_MARKER,
            )
        ) {
            throw new InvalidArgumentException(
                'Visual button block is invalid.',
            );
        }

        return [
            'id' => $block['id'],
            'type' => 'button',
            'label' => $block['label'],
            'url'
                => self::httpsUrl(
                    $block['url']
                    ?? null,
                ),
            'align'
                => self::alignment(
                    $block['align']
                    ?? null,
                ),
        ];
    }

    /**
     * @param array<string,mixed> $block
     * @return array<string,mixed>
     */
    private function columnsBlock(
        array $block,
    ): array {
        if (
            !self::keysAre(
                $block,
                [
                    'id',
                    'type',
                    'columns',
                ],
            )
            || !is_array(
                $block['columns']
                ?? null,
            )
            || !array_is_list(
                $block['columns'],
            )
            || count(
                $block['columns'],
            ) !== 2
        ) {
            throw new InvalidArgumentException(
                'Visual columns block is invalid.',
            );
        }

        $columns = [];

        foreach (
            $block['columns']
            as $column
        ) {
            if (
                !is_array($column)
                || array_is_list(
                    $column,
                )
                || !self::keysAre(
                    $column,
                    [
                        'text',
                        'align',
                    ],
                )
                || !self::validText(
                    $column['text']
                    ?? null,
                )
            ) {
                throw new InvalidArgumentException(
                    'Visual column content is invalid.',
                );
            }

            $columns[] = [
                'text'
                    => $column['text'],
                'align'
                    => self::alignment(
                        $column['align']
                        ?? null,
                    ),
            ];
        }

        return [
            'id' => $block['id'],
            'type' => 'columns',
            'columns' => $columns,
        ];
    }

    /**
     * @param array<string,mixed> $block
     */
    private function renderBlock(
        array $block,
    ): string {
        return match (
            $block['type']
        ) {
            'text'
                => sprintf(
                    '<tr><td style="padding:12px 24px;text-align:%s;font-family:Arial,sans-serif;font-size:16px;line-height:1.6;color:#172033">%s</td></tr>',
                    $block['align'],
                    self::visualText(
                        $block['text'],
                        true,
                    ),
                ),
            'image'
                => sprintf(
                    '<tr><td style="padding:12px 24px;text-align:%s"><img src="%s" alt="%s" style="display:inline-block;max-width:100%%;height:auto;border:0"></td></tr>',
                    $block['align'],
                    self::escape(
                        $block['url'],
                    ),
                    self::visualText(
                        $block['alt'],
                        false,
                    ),
                ),
            'button'
                => sprintf(
                    '<tr><td style="padding:12px 24px;text-align:%s"><a href="%s" style="display:inline-block;padding:12px 18px;background:#0f766e;color:#ffffff;text-decoration:none;border-radius:6px;font-family:Arial,sans-serif;font-size:15px;font-weight:700">%s</a></td></tr>',
                    $block['align'],
                    self::escape(
                        $block['url'],
                    ),
                    self::visualText(
                        $block['label'],
                        false,
                    ),
                ),
            'columns'
                => sprintf(
                    '<tr><td style="padding:12px 24px"><table role="presentation" width="100%%" cellspacing="0" cellpadding="0" border="0" style="width:100%%;border-collapse:collapse"><tbody><tr><td width="50%%" valign="top" style="width:50%%;padding:0 8px 0 0;text-align:%s;font-family:Arial,sans-serif;font-size:16px;line-height:1.6;color:#172033">%s</td><td width="50%%" valign="top" style="width:50%%;padding:0 0 0 8px;text-align:%s;font-family:Arial,sans-serif;font-size:16px;line-height:1.6;color:#172033">%s</td></tr></tbody></table></td></tr>',
                    $block['columns'][0]['align'],
                    self::visualText(
                        $block['columns'][0]['text'],
                        true,
                    ),
                    $block['columns'][1]['align'],
                    self::visualText(
                        $block['columns'][1]['text'],
                        true,
                    ),
                ),
            default
                => throw new InvalidArgumentException(
                    'Unsupported visual email block type.',
                ),
        };
    }

    private static function validText(
        mixed $value,
    ): bool {
        return is_string($value)
            && strlen(
                $value,
            ) <= self::MAX_TEXT_BYTES
            && !str_contains(
                $value,
                "\0",
            )
            && !str_contains(
                $value,
                self::INTERNAL_MARKER,
            );
    }

    private static function alignment(
        mixed $value,
    ): string {
        if (
            !is_string($value)
            || !in_array(
                $value,
                [
                    'left',
                    'center',
                    'right',
                ],
                true,
            )
        ) {
            throw new InvalidArgumentException(
                'Visual email alignment is invalid.',
            );
        }

        return $value;
    }

    private static function httpsUrl(
        mixed $value,
    ): string {
        if (
            !is_string($value)
            || $value === ''
            || strlen($value)
                > self::MAX_URL_BYTES
            || str_contains(
                $value,
                '{{',
            )
            || preg_match(
                '/[\x00-\x20\x7F]/',
                $value,
            ) === 1
            || filter_var(
                $value,
                FILTER_VALIDATE_URL,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Visual email URL is invalid.',
            );
        }

        $parts =
            parse_url(
                $value,
            );

        if (
            !is_array($parts)
            || strtolower(
                (string) (
                    $parts['scheme']
                    ?? ''
                ),
            ) !== 'https'
            || !is_string(
                $parts['host']
                ?? null,
            )
            || $parts['host'] === ''
            || isset(
                $parts['user'],
            )
            || isset(
                $parts['pass'],
            )
        ) {
            throw new InvalidArgumentException(
                'Visual email URL must use HTTPS without userinfo.',
            );
        }

        return $value;
    }

    /**
     * @param array<string,mixed> $value
     * @param list<string> $expected
     */
    private static function keysAre(
        array $value,
        array $expected,
    ): bool {
        $actual =
            array_keys(
                $value,
            );

        sort(
            $actual,
            SORT_STRING,
        );

        sort(
            $expected,
            SORT_STRING,
        );

        return $actual === $expected;
    }

    private static function visualText(
        string $value,
        bool $lineBreaks,
    ): string {
        $escaped =
            self::escape(
                $value,
            );

        $marked =
            preg_replace_callback(
                '/\{\{([a-z][a-z0-9_]{0,63})\}\}/',
                static fn (
                    array $matches,
                ): string => sprintf(
                    '[[HMHTML:%s]]',
                    $matches[1],
                ),
                $escaped,
            );

        if (!is_string($marked)) {
            throw new InvalidArgumentException(
                'Unable to render visual email text.',
            );
        }

        return $lineBreaks
            ? nl2br(
                $marked,
                false,
            )
            : $marked;
    }

    private static function escape(
        string $value,
    ): string {
        return htmlspecialchars(
            $value,
            ENT_QUOTES
            | ENT_SUBSTITUTE
            | ENT_HTML5,
            'UTF-8',
        );
    }
}
