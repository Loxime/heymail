<?php

declare(strict_types=1);

namespace App\Controller;

use App\Api\ApiCredentials;
use App\Api\ApiSendQuotaLimiter;
use App\Entity\OutboundMessage;
use App\Enum\OutboundMessageEventType;
use App\Enum\OutboundMessageStatus;
use App\Mail\IdempotencyConflictException;
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundMessageSubmissionService;
use App\Mail\SenderAuthorizationService;
use App\Query\OutboundMessageQueryService;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\ORM\EntityManagerInterface;
use InvalidArgumentException;
use JsonException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/api/v1')]
final readonly class TransactionalMailController
{
    private const int MAX_REQUEST_BYTES = 3500000;

    public function __construct(
        private ApiCredentials $credentials,
        private ApiSendQuotaLimiter $sendQuotaLimiter,
        private OutboundMessageSubmissionService $submissionService,
        private SenderAuthorizationService $senderAuthorization,
        private EntityManagerInterface $entityManager,
        private OutboundMessageQueryService $messageQuery,
    ) {
    }

    #[Route(
        '/send',
        name: 'api_v1_send',
        methods: ['POST'],
    )]
    public function send(
        Request $request,
    ): JsonResponse {
        $apiKeyFingerprint =
            $this
                ->credentials
                ->authorizedKeyFingerprint(
                    $request,
                );

        if ($apiKeyFingerprint === null) {
            return self::unauthorized();
        }

        $retryAfter =
            $this
                ->sendQuotaLimiter
                ->consume(
                    $apiKeyFingerprint,
                );

        if ($retryAfter !== null) {
            $response = self::error(
                'rate_limited',
                'Hourly send request quota exceeded.',
                Response::HTTP_TOO_MANY_REQUESTS,
            );

            $response->headers->set(
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

        $rawContent = $request->getContent();

        if (
            strlen($rawContent)
            > self::MAX_REQUEST_BYTES
        ) {
            return self::error(
                'payload_too_large',
                'Request body is too large.',
                Response::HTTP_REQUEST_ENTITY_TOO_LARGE,
            );
        }

        $idempotencyKey = $request
            ->headers
            ->get('Idempotency-Key');

        if (!is_string($idempotencyKey)) {
            return self::error(
                'invalid_idempotency_key',
                'Idempotency-Key header is required.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        try {
            $decoded = json_decode(
                $rawContent,
                true,
                32,
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
        ) {
            return self::error(
                'invalid_payload',
                'Request body must contain a JSON object.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $payload =
                OutboundEmailPayload::fromArray(
                    $decoded,
                );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_payload',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        if (
            !$this
                ->senderAuthorization
                ->authorizes(
                    $payload->from,
                )
        ) {
            return self::error(
                'sender_not_authorized',
                'From address is not an authorized sender.',
                Response::HTTP_FORBIDDEN,
            );
        }

        try {
            $submission =
                $this->submissionService->submit(
                    $idempotencyKey,
                    $payload,
                );
        } catch (IdempotencyConflictException) {
            return self::error(
                'idempotency_conflict',
                'Idempotency-Key is already associated with another message.',
                Response::HTTP_CONFLICT,
            );
        } catch (InvalidArgumentException) {
            return self::error(
                'invalid_idempotency_key',
                'Idempotency-Key is invalid.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        $response = new JsonResponse(
            [
                'messageId'
                    => $submission->messageId,
                'status'
                    => $submission->status->value,
                'replayed'
                    => $submission->replayed,
            ],
            $submission->replayed
                ? Response::HTTP_OK
                : Response::HTTP_ACCEPTED,
        );

        if (!$submission->replayed) {
            $response->headers->set(
                'Location',
                sprintf(
                    '/api/v1/messages/%d',
                    $submission->messageId,
                ),
            );
        }

        return $response;
    }

    #[Route(
        '/messages',
        name: 'api_v1_messages',
        methods: ['GET'],
    )]
    public function messages(
        Request $request,
    ): JsonResponse {
        if (
            !$this->credentials->authorizes(
                $request,
            )
        ) {
            return self::unauthorized();
        }

        $query =
            $request
                ->query
                ->all();

        $allowed = [
            'limit',
            'cursor',
            'status',
            'event',
            'createdAfter',
            'createdBefore',
        ];

        foreach (array_keys($query) as $key) {
            if (
                !is_string($key)
                || !in_array(
                    $key,
                    $allowed,
                    true,
                )
            ) {
                return self::error(
                    'invalid_query',
                    'Unexpected query parameter.',
                    Response::HTTP_BAD_REQUEST,
                );
            }
        }

        foreach ($query as $value) {
            if (!is_string($value)) {
                return self::error(
                    'invalid_query',
                    'Query parameters must be scalar strings.',
                    Response::HTTP_BAD_REQUEST,
                );
            }
        }

        $limitRaw =
            $query['limit']
            ?? '50';

        if (
            preg_match(
                '/^[1-9][0-9]{0,2}$/D',
                $limitRaw,
            ) !== 1
        ) {
            return self::error(
                'invalid_query',
                'limit must be between 1 and 100.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        $limit = (int) $limitRaw;

        if ($limit > 100) {
            return self::error(
                'invalid_query',
                'limit must be between 1 and 100.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        $cursor =
            $query['cursor']
            ?? null;

        if (
            $cursor !== null
            && (
                $cursor === ''
                || strlen($cursor) > 512
            )
        ) {
            return self::error(
                'invalid_query',
                'Invalid cursor.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        $status = null;

        if (isset($query['status'])) {
            $status =
                OutboundMessageStatus::tryFrom(
                    $query['status'],
                );

            if ($status === null) {
                return self::error(
                    'invalid_query',
                    'Invalid message status.',
                    Response::HTTP_BAD_REQUEST,
                );
            }
        }

        $event = null;

        if (isset($query['event'])) {
            $event =
                OutboundMessageEventType::tryFrom(
                    $query['event'],
                );

            if ($event === null) {
                return self::error(
                    'invalid_query',
                    'Invalid message event.',
                    Response::HTTP_BAD_REQUEST,
                );
            }
        }

        try {
            $createdAfter =
                isset($query['createdAfter'])
                    ? self::parseDateQuery(
                        $query['createdAfter'],
                    )
                    : null;

            $createdBefore =
                isset($query['createdBefore'])
                    ? self::parseDateQuery(
                        $query['createdBefore'],
                    )
                    : null;
        } catch (InvalidArgumentException) {
            return self::error(
                'invalid_query',
                'Dates must be RFC 3339 timestamps.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        if (
            $createdAfter !== null
            && $createdBefore !== null
            && $createdAfter >= $createdBefore
        ) {
            return self::error(
                'invalid_query',
                'createdAfter must be before createdBefore.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        try {
            $result =
                $this
                    ->messageQuery
                    ->list(
                        limit: $limit,
                        cursor: $cursor,
                        status: $status,
                        event: $event,
                        createdAfter: $createdAfter,
                        createdBefore: $createdBefore,
                    );
        } catch (InvalidArgumentException) {
            return self::error(
                'invalid_query',
                'Invalid cursor.',
                Response::HTTP_BAD_REQUEST,
            );
        }

        return new JsonResponse(
            $result,
        );
    }

    #[Route(
        '/messages/{id}',
        name: 'api_v1_message_status',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['GET'],
    )]
    public function status(
        Request $request,
        string $id,
    ): JsonResponse {
        if (
            !$this->credentials->authorizes(
                $request,
            )
        ) {
            return self::unauthorized();
        }

        $messageId = filter_var(
            $id,
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        if (!is_int($messageId)) {
            return self::error(
                'message_not_found',
                'Outbound message was not found.',
                Response::HTTP_NOT_FOUND,
            );
        }

        $message = $this
            ->entityManager
            ->find(
                OutboundMessage::class,
                $messageId,
            );

        if (
            !$message
            instanceof OutboundMessage
        ) {
            return self::error(
                'message_not_found',
                'Outbound message was not found.',
                Response::HTTP_NOT_FOUND,
            );
        }

        $events = [];
        $deliverySummary = [
            'delivered' => 0,
            'tempfail' => 0,
            'bounced' => 0,
        ];

        foreach (
            $message->getEvents()
            as $event
        ) {
            $type =
                $event
                    ->getType()
                    ->value;

            if (
                array_key_exists(
                    $type,
                    $deliverySummary,
                )
            ) {
                ++$deliverySummary[$type];
            }

            $events[] = [
                'type' => $type,
                'occurredAt'
                    => $event
                        ->getOccurredAt()
                        ->format(DATE_ATOM),
                'recipientHash'
                    => $event
                        ->getRecipientHash(),
                'smtpStatus'
                    => $event
                        ->getSmtpStatus(),
                'detail'
                    => $event
                        ->getDetail(),
            ];
        }

        return new JsonResponse([
            'messageId' => $messageId,
            'status'
                => $message
                    ->getStatus()
                    ->value,
            'createdAt'
                => $message
                    ->getCreatedAt()
                    ->format(DATE_ATOM),
            'readyForSubmissionAt'
                => $message
                    ->getReadyForSubmissionAt()
                    ?->format(DATE_ATOM),
            'submittingAt'
                => $message
                    ->getSubmittingAt()
                    ?->format(DATE_ATOM),
            'submissionUncertainAt'
                => $message
                    ->getSubmissionUncertainAt()
                    ?->format(DATE_ATOM),
            'submittedAt'
                => $message
                    ->getSubmittedAt()
                    ?->format(DATE_ATOM),
            'deliverySummary'
                => $deliverySummary,
            'events'
                => $events,
        ]);
    }

    private static function parseDateQuery(
        string $value,
    ): DateTimeImmutable {
        if (
            strlen($value) > 64
            || preg_match(
                '/^\d{4}-\d{2}-\d{2}T'
                . '\d{2}:\d{2}:\d{2}'
                . '(?:\.\d{1,6})?'
                . '(?:Z|[+-]\d{2}:\d{2})$/D',
                $value,
            ) !== 1
        ) {
            throw new InvalidArgumentException(
                'Invalid date.',
            );
        }

        try {
            return (
                new DateTimeImmutable(
                    $value,
                )
            )
                ->setTimezone(
                    new DateTimeZone(
                        'UTC',
                    ),
                );
        } catch (\Exception $exception) {
            throw new InvalidArgumentException(
                'Invalid date.',
                0,
                $exception,
            );
        }
    }

    private static function unauthorized(): JsonResponse
    {
        $response = self::error(
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
