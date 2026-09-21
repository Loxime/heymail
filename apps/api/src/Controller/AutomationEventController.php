<?php

declare(strict_types=1);

namespace App\Controller;

use App\Api\ApiCredentials;
use App\Automation\ApiEventAutomationTrigger;
use App\Automation\AutomationApiEventConflictException;
use App\Automation\AutomationApiEventQuotaLimiter;
use App\Mail\EmailAddress;
use InvalidArgumentException;
use JsonException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/api/v1/automation-events')]
final readonly class AutomationEventController
{
    private const int MAX_REQUEST_BYTES = 65536;

    public function __construct(
        private ApiCredentials $credentials,
        private AutomationApiEventQuotaLimiter $quotaLimiter,
        private ApiEventAutomationTrigger $trigger,
    ) {
    }

    #[Route(
        '/{eventName}',
        name: 'api_v1_automation_event',
        requirements: [
            'eventName'
                => '[a-z][a-z0-9_.-]{0,63}',
        ],
        methods: ['POST'],
    )]
    public function event(
        Request $request,
        string $eventName,
    ): JsonResponse {
        $principal =
            $this
                ->credentials
                ->authorizedPrincipal(
                    $request,
                );

        if ($principal === null) {
            return self::unauthorized();
        }

        $retryAfter =
            $this
                ->quotaLimiter
                ->consume(
                    $principal->keyFingerprint,
                );

        if ($retryAfter !== null) {
            $response = self::error(
                'rate_limited',
                'Hourly automation event quota exceeded.',
                Response::HTTP_TOO_MANY_REQUESTS,
            );

            $response
                ->headers
                ->set(
                    'Retry-After',
                    (string) $retryAfter,
                );

            return $response;
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

        $raw =
            $request
                ->getContent();

        if (
            $raw === ''
            || strlen($raw)
                > self::MAX_REQUEST_BYTES
        ) {
            return self::error(
                'invalid_payload',
                'Automation event body must contain between 1 and 65536 bytes.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $idempotencyKey =
            $request
                ->headers
                ->get(
                    'Idempotency-Key',
                );

        if (!is_string($idempotencyKey)) {
            return self::error(
                'invalid_idempotency_key',
                'Idempotency-Key header is required.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        try {
            $payload =
                json_decode(
                    $raw,
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
            !is_array($payload)
            || array_is_list($payload)
        ) {
            return self::error(
                'invalid_payload',
                'Request body must contain a JSON object.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $keys =
            array_keys(
                $payload,
            );

        if (
            array_diff(
                $keys,
                [
                    'recipient',
                    'variables',
                ],
            ) !== []
            || !array_key_exists(
                'recipient',
                $payload,
            )
        ) {
            return self::error(
                'invalid_payload',
                'Expected recipient and optional variables.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $recipientRaw =
            $payload['recipient'];

        if (
            !is_array($recipientRaw)
            || array_is_list($recipientRaw)
        ) {
            return self::error(
                'invalid_payload',
                'recipient must be an object.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $variables =
            $payload['variables']
            ?? [];

        if (
            !is_array($variables)
            || (
                $variables !== []
                && array_is_list(
                    $variables,
                )
            )
        ) {
            return self::error(
                'invalid_payload',
                'variables must be a JSON object.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $recipient =
                EmailAddress::fromArray(
                    $recipientRaw,
                );

            $result =
                $this
                    ->trigger
                    ->accept(
                        $principal->workspaceId,
                        $principal->keyFingerprint,
                        $idempotencyKey,
                        $eventName,
                        $recipient,
                        $variables,
                    );
        } catch (AutomationApiEventConflictException) {
            return self::error(
                'idempotency_conflict',
                'Idempotency-Key is already associated with another automation event.',
                Response::HTTP_CONFLICT,
            );
        } catch (InvalidArgumentException $exception) {
            $code =
                str_contains(
                    strtolower(
                        $exception->getMessage(),
                    ),
                    'idempotency',
                )
                    ? 'invalid_idempotency_key'
                    : 'invalid_payload';

            return self::error(
                $code,
                $exception->getMessage(),
                $code === 'invalid_idempotency_key'
                    ? Response::HTTP_BAD_REQUEST
                    : Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $response =
            new JsonResponse(
                [
                    'eventId'
                        => $result['eventId'],
                    'eventName'
                        => $eventName,
                    'matchedAutomations'
                        => $result['matchedAutomations'],
                    'replayed'
                        => $result['replayed'],
                ],
                $result['replayed']
                    ? Response::HTTP_OK
                    : Response::HTTP_ACCEPTED,
            );

        $response
            ->headers
            ->set(
                'Cache-Control',
                'no-store',
            );

        return $response;
    }

    private static function unauthorized():
    JsonResponse {
        $response = self::error(
            'unauthorized',
            'Valid API credentials are required.',
            Response::HTTP_UNAUTHORIZED,
        );

        $response
            ->headers
            ->set(
                'WWW-Authenticate',
                'Basic realm="HeyMail API", charset="UTF-8"',
            );

        return $response;
    }

    private static function error(
        string $code,
        string $message,
        int $status,
    ): JsonResponse {
        $response =
            new JsonResponse(
                [
                    'error' => [
                        'code'
                            => $code,
                        'message'
                            => $message,
                    ],
                ],
                $status,
            );

        $response
            ->headers
            ->set(
                'Cache-Control',
                'no-store',
            );

        return $response;
    }
}
