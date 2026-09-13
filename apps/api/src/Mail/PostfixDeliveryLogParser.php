<?php

declare(strict_types=1);

namespace App\Mail;

use App\Enum\OutboundMessageEventType;
use InvalidArgumentException;

final class PostfixDeliveryLogParser
{
    /**
     * @var array<string, int>
     */
    private array $messageByQueueId = [];

    public function __construct(
        private readonly string $bounceDomain,
    ) {
        if (
            $bounceDomain === ''
            || str_contains(
                $bounceDomain,
                '@',
            )
        ) {
            throw new InvalidArgumentException(
                'Invalid bounce domain.',
            );
        }
    }

    public function reset(): void
    {
        $this->messageByQueueId = [];
    }

    public function consume(
        string $line,
    ): ?PostfixDeliveryFeedback {
        $line = rtrim(
            $line,
            "\r\n",
        );

        $domain =
            preg_quote(
                $this->bounceDomain,
                '/',
            );

        if (
            preg_match(
                '/\b([A-Za-z0-9]+): '
                . 'from=<bounce\+([1-9][0-9]*)'
                . '(?:\+[a-f0-9]{32})?@'
                . $domain
                . '>/i',
                $line,
                $match,
            ) === 1
        ) {
            $this->messageByQueueId[
                strtoupper($match[1])
            ] = (int) $match[2];

            return null;
        }

        if (
            preg_match(
                '/\b([A-Za-z0-9]+): '
                . 'message-id=<heymail-([1-9][0-9]*)@'
                . $domain
                . '>/i',
                $line,
                $match,
            ) === 1
        ) {
            $this->messageByQueueId[
                strtoupper($match[1])
            ] = (int) $match[2];

            return null;
        }

        if (
            preg_match(
                '/\b([A-Za-z0-9]+): removed\b/i',
                $line,
                $match,
            ) === 1
        ) {
            unset(
                $this->messageByQueueId[
                    strtoupper($match[1])
                ],
            );

            return null;
        }

        if (
            preg_match(
                '/\b([A-Za-z0-9]+): '
                . 'to=<([^>]*)>,.*'
                . '\bdsn=([245]\.[0-9]{1,3}\.[0-9]{1,3}), '
                . 'status=(sent|deferred|bounced)'
                . '(?: \((.*)\))?$/i',
                $line,
                $match,
            ) !== 1
        ) {
            return null;
        }

        $queueId =
            strtoupper(
                $match[1],
            );

        $messageId =
            $this->messageByQueueId[
                $queueId
            ] ?? null;

        if (!is_int($messageId)) {
            return null;
        }

        $type = match (
            strtolower($match[4])
        ) {
            'sent'
                => OutboundMessageEventType::DELIVERED,

            'deferred'
                => OutboundMessageEventType::TEMPFAIL,

            'bounced'
                => OutboundMessageEventType::BOUNCED,
        };

        $detail = $match[5]
            ?? strtolower(
                $match[4],
            );

        $detail = preg_replace(
            '/[\x00-\x1F\x7F]+/',
            ' ',
            $detail,
        ) ?? '';

        $detail = trim(
            $detail,
        );

        /*
         * Remote SMTP diagnostics are untrusted and may echo the
         * recipient address. Persist only the recipient hash.
         */
        $detail = str_ireplace(
            $match[2],
            '[recipient]',
            $detail,
        );

        if ($detail === '') {
            $detail = $type->value;
        }

        if (strlen($detail) > 1024) {
            $detail = substr(
                $detail,
                0,
                1024,
            );
        }

        return new PostfixDeliveryFeedback(
            outboundMessageId: $messageId,
            recipient: strtolower(
                $match[2],
            ),
            type: $type,
            smtpStatus: $match[3],
            detail: $detail,
            sourceEventId: hash(
                'sha256',
                $line,
            ),
        );
    }
}
