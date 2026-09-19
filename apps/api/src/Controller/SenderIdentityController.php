<?php

declare(strict_types=1);

namespace App\Controller;

use App\Api\ApiCredentials;
use App\Entity\SenderIdentity;
use App\Mail\SenderDomainNotReadyException;
use App\Mail\SenderDomainNotVerifiedException;
use App\Mail\SenderIdentityRegistrationService;
use Doctrine\ORM\EntityManagerInterface;
use InvalidArgumentException;
use JsonException;
use RuntimeException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

final readonly class SenderIdentityController
{
    private const int MAX_REQUEST_BYTES = 4096;

    public function __construct(
        private ApiCredentials $credentials,
        private SenderIdentityRegistrationService $registrationService,
        private EntityManagerInterface $entityManager,
    ) {
    }

    #[Route(
        '/api/v1/senders',
        name: 'api_v1_sender_create',
        methods: ['POST'],
    )]
    public function create(
        Request $request,
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

        $rawContent =
            $request->getContent();

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

        try {
            $decoded =
                json_decode(
                    $rawContent,
                    true,
                    8,
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
            || array_keys($decoded)
                !== ['email']
            || !is_string(
                $decoded['email'],
            )
        ) {
            return self::error(
                'invalid_payload',
                'Request body must contain exactly one string field named email.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $registration =
                $this
                    ->registrationService
                    ->register(
                        $decoded['email'],
                        $principal->workspaceId,
                    );
        } catch (SenderDomainNotVerifiedException) {
            return self::error(
                'sending_domain_not_verified',
                'Sender domain must be verified before registering the sender.',
                Response::HTTP_CONFLICT,
            );
        } catch (SenderDomainNotReadyException) {
            return self::error(
                'sending_domain_not_ready',
                'Sender domain DKIM must be provisioned before registering the sender.',
                Response::HTTP_CONFLICT,
            );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_sender',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $document =
            self::serializeSender(
                $registration->sender,
            );

        $document['replayed'] =
            $registration->replayed;

        $response =
            new JsonResponse(
                $document,
                $registration->replayed
                    ? Response::HTTP_OK
                    : Response::HTTP_CREATED,
            );

        if (!$registration->replayed) {
            $response
                ->headers
                ->set(
                    'Location',
                    sprintf(
                        '/api/v1/senders/%d',
                        $document['id'],
                    ),
                );
        }

        return $response;
    }

    #[Route(
        '/api/v1/senders',
        name: 'api_v1_senders',
        methods: ['GET'],
    )]
    public function list(
        Request $request,
    ): JsonResponse {
        if (
            !$this->credentials->authorizes(
                $request,
            )
        ) {
            return self::unauthorized();
        }

        $senders =
            $this
                ->entityManager
                ->getRepository(
                    SenderIdentity::class,
                )
                ->findBy(
                    [],
                    [
                        'id' => 'DESC',
                    ],
                );

        return new JsonResponse([
            'items' =>
                array_map(
                    static fn (
                        SenderIdentity $sender,
                    ): array =>
                        self::serializeSender(
                            $sender,
                        ),
                    $senders,
                ),
        ]);
    }

    #[Route(
        '/api/v1/senders/{id}',
        name: 'api_v1_sender_status',
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

        $senderId =
            filter_var(
                $id,
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 1,
                    ],
                ],
            );

        if (!is_int($senderId)) {
            return self::notFound();
        }

        $sender =
            $this
                ->entityManager
                ->find(
                    SenderIdentity::class,
                    $senderId,
                );

        if (
            !$sender
            instanceof SenderIdentity
        ) {
            return self::notFound();
        }

        return new JsonResponse(
            self::serializeSender(
                $sender,
            ),
        );
    }

    /**
     * @return array{
     *     id: int,
     *     email: string,
     *     domain: string,
     *     authorized: bool,
     *     createdAt: string
     * }
     */
    private static function serializeSender(
        SenderIdentity $sender,
    ): array {
        $id =
            $sender->getId();

        if (
            !is_int($id)
            || $id < 1
        ) {
            throw new RuntimeException(
                'Persisted sender identity has no valid identifier.',
            );
        }

        return [
            'id' => $id,
            'email'
                => $sender
                    ->getEmail(),
            'domain'
                => $sender
                    ->getSendingDomain()
                    ->getDomain(),
            'authorized'
                => $sender
                    ->isAuthorized(),
            'createdAt'
                => $sender
                    ->getCreatedAt()
                    ->format(DATE_ATOM),
        ];
    }

    private static function unauthorized(): JsonResponse
    {
        $response =
            self::error(
                'unauthorized',
                'Invalid API credentials.',
                Response::HTTP_UNAUTHORIZED,
            );

        $response
            ->headers
            ->set(
                'WWW-Authenticate',
                'Basic realm="HeyMail API"',
            );

        return $response;
    }

    private static function notFound(): JsonResponse
    {
        return self::error(
            'sender_not_found',
            'Sender identity was not found.',
            Response::HTTP_NOT_FOUND,
        );
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
