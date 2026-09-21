<?php

declare(strict_types=1);

namespace App\Tracking;

use InvalidArgumentException;

final readonly class TrackingHtmlInstrumenter
{
    public function __construct(
        private TrackingTokenCodec $tokens,
    ) {
    }

    public function instrument(
        string $html,
        int $campaignId,
        int $recipientIndex,
    ): string {
        if (
            $campaignId < 1
            || $recipientIndex < 0
        ) {
            throw new InvalidArgumentException(
                'Invalid campaign tracking context.',
            );
        }

        $rewritten = preg_replace_callback(
            '~<a\b[^>]*>~iu',
            function (array $matches) use (
                $campaignId,
                $recipientIndex,
            ): string {
                $tag = $matches[0];

                return preg_replace_callback(
                    '~\bhref\s*=\s*(["\'])(.*?)\1~isu',
                    function (array $href) use (
                        $campaignId,
                        $recipientIndex,
                    ): string {
                        $destination = html_entity_decode(
                            $href[2],
                            ENT_QUOTES | ENT_HTML5,
                            'UTF-8',
                        );

                        try {
                            $url = $this->tokens->clickUrl(
                                $campaignId,
                                $recipientIndex,
                                $destination,
                            );
                        } catch (InvalidArgumentException) {
                            return $href[0];
                        }

                        return sprintf(
                            'href=%1$s%2$s%1$s',
                            $href[1],
                            htmlspecialchars(
                                $url,
                                ENT_QUOTES
                                | ENT_SUBSTITUTE
                                | ENT_HTML5,
                                'UTF-8',
                            ),
                        );
                    },
                    $tag,
                    1,
                ) ?? $tag;
            },
            $html,
        );

        if ($rewritten === null) {
            throw new InvalidArgumentException(
                'Unable to instrument campaign HTML.',
            );
        }

        $openUrl = htmlspecialchars(
            $this->tokens->openUrl(
                $campaignId,
                $recipientIndex,
            ),
            ENT_QUOTES
            | ENT_SUBSTITUTE
            | ENT_HTML5,
            'UTF-8',
        );

        return $rewritten
            . sprintf(
                '<img src="%s" width="1" height="1" alt="" style="display:block;width:1px;height:1px;border:0" aria-hidden="true">',
                $openUrl,
            );
    }
}
