<?php

declare(strict_types=1);

namespace App\Controller;

use App\Api\ApiCredentials;
use App\Enum\OutboundMessageEventType;
use App\Webhook\WebhookRegistrationService;
use InvalidArgumentException;
use JsonException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/api/v1/webhooks')]
final readonly class WebhookController
{
    public function __construct(
        private ApiCredentials $credentials,
        private WebhookRegistrationService $registrationService,
    ) {
    }

    #[Route(
        '',
        name: 'api_v1_webhooks_create',
        methods: ['POST'],
    )]
    public function create(
        Request $request,
    ): JsonResponse {
        if (
            !$this->credentials
                ->authorizes(
                    $request,
                )
        ) {
            return self::unauthorized();
        }

        if (
            $request->getContentTypeFormat()
            !== 'json'
        ) {
            return self::error(
                'unsupported_media_type',
                'Content-Type must be application/json.',
                Response::HTTP_UNSUPPORTED_MEDIA_TYPE,
            );
        }

        if (
            strlen(
                $request->getContent(),
            ) > 65536
        ) {
            return self::error(
                'payload_too_large',
                'Request body is too large.',
                Response::HTTP_REQUEST_ENTITY_TOO_LARGE,
            );
        }

        try {
            $decoded = json_decode(
                $request->getContent(),
                true,
                16,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException) {
            return self::error(
                'invalid_json',
                'Request body must contain valid JSON.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        if (
            !is_array($decoded)
            || array_is_list($decoded)
            || array_diff(
                array_keys($decoded),
                [
                    'url',
                    'events',
                ],
            ) !== []
        ) {
            return self::error(
                'invalid_payload',
                'Invalid webhook payload.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $url =
            $decoded['url']
            ?? null;

        $events =
            $decoded['events']
            ?? null;

        if (
            !is_string($url)
            || !is_array($events)
            || !array_is_list($events)
            || $events === []
            || count($events) > 3
        ) {
            return self::error(
                'invalid_payload',
                'Webhook URL and event list are required.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $eventTypes = [];

        foreach ($events as $event) {
            if (!is_string($event)) {
                return self::error(
                    'invalid_payload',
                    'Webhook events must be strings.',
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                );
            }

            $type =
                OutboundMessageEventType::tryFrom(
                    $event,
                );

            if (
                $type === null
                || !$type->isDelivery()
            ) {
                return self::error(
                    'invalid_payload',
                    'Unsupported webhook event.',
                    Response::HTTP_UNPROCESSABLE_ENTITY,
                );
            }

            $eventTypes[] = $type;
        }

        try {
            $registration =
                $this
                    ->registrationService
                    ->create(
                        $url,
                        $eventTypes,
                    );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_payload',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $endpoint =
            $registration->endpoint;

        $response =
            new JsonResponse(
                [
                    'webhookId'
                        => $endpoint
                            ->getPublicId(),
                    'url'
                        => $endpoint
                            ->getUrl(),
                    'events'
                        => array_map(
                            static fn (
                                OutboundMessageEventType $type,
                            ): string
                                => $type->value,
                            $endpoint
                                ->getEventTypes(),
                        ),
                    'enabled'
                        => $endpoint
                            ->isEnabled(),
                    'createdAt'
                        => $endpoint
                            ->getCreatedAt()
                            ->format(DATE_ATOM),
                    /*
                     * Returned exactly once.
                     */
                    'secret'
                        => $registration
                            ->secret,
                ],
                Response::HTTP_CREATED,
            );

        $response->headers->set(
            'Cache-Control',
            'no-store',
        );

        return $response;
    }

    #[Route(
        '',
        name: 'api_v1_webhooks_list',
        methods: ['GET'],
    )]
    public function list(
        Request $request,
    ): JsonResponse {
        if (
            !$this->credentials
                ->authorizes(
                    $request,
                )
        ) {
            return self::unauthorized();
        }

        $items = [];

        foreach (
            $this
                ->registrationService
                ->all()
            as $endpoint
        ) {
            $items[] = [
                'webhookId'
                    => $endpoint
                        ->getPublicId(),
                'url'
                    => $endpoint
                        ->getUrl(),
                'events'
                    => array_map(
                        static fn (
                            OutboundMessageEventType $type,
                        ): string
                            => $type->value,
                        $endpoint
                            ->getEventTypes(),
                    ),
                'enabled'
                    => $endpoint
                        ->isEnabled(),
                'createdAt'
                    => $endpoint
                        ->getCreatedAt()
                        ->format(DATE_ATOM),
            ];
        }

        return new JsonResponse([
            'items' => $items,
        ]);
    }

    private static function unauthorized(): JsonResponse
    {
        $response =
            self::error(
                'unauthorized',
                'Invalid API credentials.',
                Response::HTTP_UNAUTHORIZED,
            );

        $response->headers->set(
            'WWW-Authenticate',
            'Basic realm="HeyMail API"',
        );

        return $response;
    }

    private static function error(
        string $code,
        string $message,
        int $status,
    ): JsonResponse {
        return new JsonResponse(
            [
                'error' => [
                    'code' => $code,
                    'message' => $message,
                ],
            ],
            $status,
        );
    }
}
