<?php

declare(strict_types=1);

namespace App\Webhook;

use App\Entity\WebhookDelivery;
use JsonException;
use RuntimeException;

final readonly class WebhookRequestFactory
{
    public function __construct(
        private WebhookSecretCipher $secretCipher,
    ) {
    }

    public function create(
        WebhookDelivery $delivery,
        int $timestamp,
    ): WebhookRequest {
        if ($timestamp < 1) {
            throw new RuntimeException(
                'Invalid webhook timestamp.',
            );
        }

        $endpoint =
            $delivery->getEndpoint();

        $event =
            $delivery->getEvent();

        $message =
            $event->getOutboundMessage();

        $messageId =
            $message->getId();

        if (
            !is_int($messageId)
            || $messageId < 1
        ) {
            throw new RuntimeException(
                'Webhook event message has no identifier.',
            );
        }

        try {
            $body =
                json_encode(
                    [
                        'id'
                            => $delivery
                                ->getPublicId(),
                        'type'
                            => $event
                                ->getType()
                                ->value,
                        'occurredAt'
                            => $event
                                ->getOccurredAt()
                                ->format(DATE_ATOM),
                        'message' => [
                            'id'
                                => $messageId,
                            'status'
                                => $message
                                    ->getStatus()
                                    ->value,
                        ],
                        'delivery' => [
                            'recipientHash'
                                => $event
                                    ->getRecipientHash(),
                            'smtpStatus'
                                => $event
                                    ->getSmtpStatus(),
                            'detail'
                                => $event
                                    ->getDetail(),
                        ],
                    ],
                    JSON_THROW_ON_ERROR
                    | JSON_UNESCAPED_SLASHES
                    | JSON_UNESCAPED_UNICODE,
                );
        } catch (JsonException $exception) {
            throw new RuntimeException(
                'Unable to encode webhook payload.',
                0,
                $exception,
            );
        }

        $secret =
            $this
                ->secretCipher
                ->decrypt(
                    $endpoint
                        ->getPublicId(),
                    $endpoint
                        ->encryptedSecret(),
                );

        $timestampValue =
            (string) $timestamp;

        $signature =
            hash_hmac(
                'sha256',
                $timestampValue
                . '.'
                . $body,
                $secret,
            );

        return new WebhookRequest(
            body: $body,
            timestamp: $timestampValue,
            signature:
                'v1='
                . $signature,
        );
    }
}
