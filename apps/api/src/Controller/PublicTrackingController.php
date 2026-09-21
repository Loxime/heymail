<?php

declare(strict_types=1);

namespace App\Controller;

use App\Tracking\TrackingTokenCodec;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use Symfony\Component\HttpFoundation\RedirectResponse;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/track')]
final readonly class PublicTrackingController
{
    public function __construct(
        private Connection $connection,
        private TrackingTokenCodec $tokens,
    ) {
    }

    #[Route(
        '/open/{token}',
        name: 'public_tracking_open',
        requirements: [
            'token' => 't1\.[A-Za-z0-9_-]{32,4000}',
        ],
        methods: ['GET'],
    )]
    public function open(
        string $token,
    ): Response {
        try {
            $decoded = $this->tokens->decode(
                $token,
            );
        } catch (InvalidArgumentException) {
            return self::notFound();
        }

        if (
            $decoded['eventType'] !== 'opened'
            || $decoded['destination'] !== null
            || !$this->record(
                campaignId: $decoded['campaignId'],
                recipientIndex: $decoded['recipientIndex'],
                eventType: 'opened',
                targetHash: null,
            )
        ) {
            return self::notFound();
        }

        $gif = base64_decode(
            'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
            true,
        );

        if ($gif === false) {
            return new Response(
                '',
                Response::HTTP_INTERNAL_SERVER_ERROR,
            );
        }

        return new Response(
            $gif,
            Response::HTTP_OK,
            self::headers('image/gif'),
        );
    }

    #[Route(
        '/click/{token}',
        name: 'public_tracking_click',
        requirements: [
            'token' => 't1\.[A-Za-z0-9_-]{32,4000}',
        ],
        methods: ['GET'],
    )]
    public function click(
        string $token,
    ): Response {
        try {
            $decoded = $this->tokens->decode(
                $token,
            );
        } catch (InvalidArgumentException) {
            return self::notFound();
        }

        $destination = $decoded['destination'];

        if (
            $decoded['eventType'] !== 'clicked'
            || !is_string($destination)
            || !$this->record(
                campaignId: $decoded['campaignId'],
                recipientIndex: $decoded['recipientIndex'],
                eventType: 'clicked',
                targetHash: hash('sha256', $destination),
            )
        ) {
            return self::notFound();
        }

        return new RedirectResponse(
            $destination,
            Response::HTTP_FOUND,
            self::headers(),
        );
    }

    private function record(
        int $campaignId,
        int $recipientIndex,
        string $eventType,
        ?string $targetHash,
    ): bool {
        $exists = (int) $this->connection->fetchOne(
            <<<'SQL'
SELECT COUNT(*)
FROM campaign c
INNER JOIN campaign_delivery cd
    ON cd.campaign_id = c.id
WHERE c.id = :campaign_id
  AND c.tracking_enabled = TRUE
  AND cd.recipient_index = :recipient_index
SQL,
            [
                'campaign_id' => $campaignId,
                'recipient_index' => $recipientIndex,
            ],
        );

        if ($exists !== 1) {
            return false;
        }

        $this->connection->executeStatement(
            <<<'SQL'
INSERT INTO campaign_tracking_event (
    campaign_id,
    recipient_index,
    event_type,
    target_hash,
    occurred_at
)
VALUES (
    :campaign_id,
    :recipient_index,
    :event_type,
    :target_hash,
    :occurred_at
)
ON CONFLICT DO NOTHING
SQL,
            [
                'campaign_id' => $campaignId,
                'recipient_index' => $recipientIndex,
                'event_type' => $eventType,
                'target_hash' => $targetHash,
                'occurred_at' => (
                    new DateTimeImmutable(
                        'now',
                        new DateTimeZone('UTC'),
                    )
                )->format('Y-m-d H:i:s'),
            ],
        );

        return true;
    }

    /** @return array<string,string> */
    private static function headers(
        ?string $contentType = null,
    ): array {
        $headers = [
            'Cache-Control' => 'no-store, no-cache, must-revalidate, max-age=0',
            'Pragma' => 'no-cache',
            'Referrer-Policy' => 'no-referrer',
            'X-Content-Type-Options' => 'nosniff',
        ];

        if ($contentType !== null) {
            $headers['Content-Type'] = $contentType;
        }

        return $headers;
    }

    private static function notFound(): Response
    {
        return new Response(
            'Not Found',
            Response::HTTP_NOT_FOUND,
            self::headers('text/plain; charset=UTF-8'),
        );
    }
}
