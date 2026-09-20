<?php

declare(strict_types=1);

namespace App\Mail;

use App\Entity\OutboundMessage;
use RuntimeException;
use SodiumException;

final readonly class OutboundMessagePayloadCryptor
{
    public function __construct(
        private OutboundEmailPayloadCipher $cipher,
    ) {
    }

    public function encrypt(
        OutboundMessage $message,
        OutboundEmailPayload $payload,
    ): EncryptedOutboundEmailPayload {
        return $this
            ->cipher
            ->encrypt(
                self::currentContext(
                    $message,
                ),
                $payload,
            );
    }

    public function decrypt(
        OutboundMessage $message,
        EncryptedOutboundEmailPayload $encrypted,
    ): OutboundEmailPayload {
        $legacyContext =
            $message
                ->getIdempotencyKeyHash();

        $currentContext =
            self::currentContext(
                $message,
            );

        if ($currentContext === $legacyContext) {
            return $this
                ->cipher
                ->decrypt(
                    $legacyContext,
                    $encrypted,
                );
        }

        try {
            return $this
                ->cipher
                ->decrypt(
                    $currentContext,
                    $encrypted,
                );
        } catch (
            RuntimeException
            | SodiumException
        ) {
            /*
             * Historical payloads were encrypted before workspace ownership
             * existed. Try their v1 idempotency-only AAD only after the
             * workspace-bound context fails cryptographically.
             */
            return $this
                ->cipher
                ->decrypt(
                    $legacyContext,
                    $encrypted,
                );
        }
    }

    private static function currentContext(
        OutboundMessage $message,
    ): string {
        $workspaceId =
            $message
                ->getWorkspaceId();

        if ($workspaceId === null) {
            return $message
                ->getIdempotencyKeyHash();
        }

        return hash(
            'sha256',
            sprintf(
                'heymail:outbound-payload:v2:%d:%s',
                $workspaceId,
                $message
                    ->getIdempotencyKeyHash(),
            ),
        );
    }
}
