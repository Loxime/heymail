<?php

declare(strict_types=1);

namespace App\Mail;

use App\Enum\OutboundMessageEventType;
use InvalidArgumentException;
use JsonException;

final readonly class DsnSpoolEvent
{
    private const KEYS = [
        'detail',
        'messageId',
        'recipientHash',
        'smtpStatus',
        'sourceEventId',
        'type',
    ];

    public function __construct(
        public int $messageId,
        public string $recipientHash,
        public OutboundMessageEventType $type,
        public string $smtpStatus,
        public string $detail,
        public string $sourceEventId,
    ) {
        if ($messageId < 1) {
            throw new InvalidArgumentException(
                'Invalid DSN message identifier.',
            );
        }

        if (
            preg_match(
                '/^[a-f0-9]{64}$/D',
                $recipientHash,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid DSN recipient hash.',
            );
        }

        if (!$type->isDelivery()) {
            throw new InvalidArgumentException(
                'Invalid DSN event type.',
            );
        }

        if (
            preg_match(
                '/^[245]\.[0-9]{1,3}\.[0-9]{1,3}$/D',
                $smtpStatus,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid DSN SMTP status.',
            );
        }

        $expectedClass = match ($type) {
            OutboundMessageEventType::DELIVERED => '2',
            OutboundMessageEventType::TEMPFAIL => '4',
            OutboundMessageEventType::BOUNCED => '5',

            default => throw new InvalidArgumentException(
                'Invalid DSN event type.',
            ),
        };

        if ($smtpStatus[0] !== $expectedClass) {
            throw new InvalidArgumentException(
                'DSN status does not match event type.',
            );
        }

        if (
            $detail === ''
            || strlen($detail) > 1024
            || str_contains(
                $detail,
                '@',
            )
            || preg_match(
                '/[\x00-\x1F\x7F]/',
                $detail,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Invalid DSN diagnostic.',
            );
        }

        if (
            preg_match(
                '/^[a-f0-9]{64}$/D',
                $sourceEventId,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid DSN source identifier.',
            );
        }

        $expectedSourceEventId = hash(
            'sha256',
            implode(
                "\0",
                [
                    'heymail-dsn-v1',
                    (string) $messageId,
                    $recipientHash,
                    $type->value,
                    $smtpStatus,
                    $detail,
                ],
            ),
        );

        if (
            !hash_equals(
                $expectedSourceEventId,
                $sourceEventId,
            )
        ) {
            throw new InvalidArgumentException(
                'DSN source identifier does not match event contents.',
            );
        }
    }

    public static function fromJson(
        string $json,
    ): self {
        try {
            $data = json_decode(
                $json,
                true,
                32,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException $exception) {
            throw new InvalidArgumentException(
                'Invalid DSN JSON.',
                0,
                $exception,
            );
        }

        if (
            !is_array($data)
            || array_is_list($data)
        ) {
            throw new InvalidArgumentException(
                'Invalid DSN document.',
            );
        }

        $keys = array_keys(
            $data,
        );

        sort(
            $keys,
        );

        if ($keys !== self::KEYS) {
            throw new InvalidArgumentException(
                'Invalid DSN schema.',
            );
        }

        $type = is_string(
            $data['type'],
        )
            ? OutboundMessageEventType::tryFrom(
                $data['type'],
            )
            : null;

        if (
            !is_int($data['messageId'])
            || !is_string($data['recipientHash'])
            || !$type instanceof OutboundMessageEventType
            || !is_string($data['smtpStatus'])
            || !is_string($data['detail'])
            || !is_string($data['sourceEventId'])
        ) {
            throw new InvalidArgumentException(
                'Invalid DSN field types.',
            );
        }

        return new self(
            messageId: $data['messageId'],
            recipientHash: $data['recipientHash'],
            type: $type,
            smtpStatus: $data['smtpStatus'],
            detail: $data['detail'],
            sourceEventId: $data['sourceEventId'],
        );
    }
}
