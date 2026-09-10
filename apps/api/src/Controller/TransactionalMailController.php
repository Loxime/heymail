<?php

declare(strict_types=1);

namespace App\Controller;

use App\Api\ApiCredentials;
use App\Entity\OutboundMessage;
use App\Mail\IdempotencyConflictException;
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundMessageSubmissionService;
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
        private OutboundMessageSubmissionService $submissionService,
        private EntityManagerInterface $entityManager,
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
        if (
            !$this->credentials->authorizes(
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
            'submittedAt'
                => $message
                    ->getSubmittedAt()
                    ?->format(DATE_ATOM),
        ]);
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
