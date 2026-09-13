<?php

declare(strict_types=1);

namespace App\Controller;

use App\Api\ApiCredentials;
use App\Entity\SendingDomain;
use App\Enum\SendingDomainStatus;
use App\Mail\SendingDomainRegistrationService;
use App\Message\ProvisionSendingDomainDkim;
use App\Message\VerifySendingDomain;
use Doctrine\ORM\EntityManagerInterface;
use InvalidArgumentException;
use JsonException;
use RuntimeException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Messenger\MessageBusInterface;
use Symfony\Component\Routing\Attribute\Route;

final readonly class SendingDomainController
{
    private const int MAX_REQUEST_BYTES = 4096;

    public function __construct(
        private ApiCredentials $credentials,
        private SendingDomainRegistrationService $registrationService,
        private EntityManagerInterface $entityManager,
        private MessageBusInterface $messageBus,
    ) {
    }

    #[Route(
        '/api/v1/domains',
        name: 'api_v1_domain_create',
        methods: ['POST'],
    )]
    public function create(
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
                !== ['domain']
            || !is_string(
                $decoded['domain'],
            )
        ) {
            return self::error(
                'invalid_payload',
                'Request body must contain exactly one string field named domain.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $registration =
                $this
                    ->registrationService
                    ->register(
                        $decoded['domain'],
                    );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_domain',
                $exception->getMessage(),
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $document =
            self::serializeDomain(
                $registration->domain,
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
                        '/api/v1/domains/%d',
                        $document['id'],
                    ),
                );
        }

        return $response;
    }

    #[Route(
        '/api/v1/domains',
        name: 'api_v1_domains',
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

        $domains =
            $this
                ->entityManager
                ->getRepository(
                    SendingDomain::class,
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
                        SendingDomain $domain,
                    ): array =>
                        self::serializeDomain(
                            $domain,
                        ),
                    $domains,
                ),
        ]);
    }

    #[Route(
        '/api/v1/domains/{id}',
        name: 'api_v1_domain_status',
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

        $domain =
            $this->findDomain(
                $id,
            );

        if (
            !$domain
            instanceof SendingDomain
        ) {
            return self::error(
                'domain_not_found',
                'Sending domain was not found.',
                Response::HTTP_NOT_FOUND,
            );
        }

        return new JsonResponse(
            self::serializeDomain(
                $domain,
            ),
        );
    }

    #[Route(
        '/api/v1/domains/{id}/verify',
        name: 'api_v1_domain_verify',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['POST'],
    )]
    public function verify(
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

        $domain =
            $this->findDomain(
                $id,
            );

        if (
            !$domain
            instanceof SendingDomain
        ) {
            return self::error(
                'domain_not_found',
                'Sending domain was not found.',
                Response::HTTP_NOT_FOUND,
            );
        }

        if (
            $domain->getStatus()
            === SendingDomainStatus::DISABLED
        ) {
            return self::error(
                'domain_disabled',
                'Disabled sending domain cannot be verified.',
                Response::HTTP_CONFLICT,
            );
        }

        $document =
            self::serializeDomain(
                $domain,
            );

        if (
            $domain->getStatus()
            === SendingDomainStatus::VERIFIED
        ) {
            $document['verificationQueued'] =
                false;

            return new JsonResponse(
                $document,
                Response::HTTP_OK,
            );
        }

        $domainId =
            $domain->getId();

        if (
            !is_int($domainId)
            || $domainId < 1
        ) {
            throw new RuntimeException(
                'Persisted sending domain has no valid identifier.',
            );
        }

        $this->messageBus
            ->dispatch(
                new VerifySendingDomain(
                    $domainId,
                ),
            );

        $document['verificationQueued'] =
            true;

        return new JsonResponse(
            $document,
            Response::HTTP_ACCEPTED,
        );
    }

    #[Route(
        '/api/v1/domains/{id}/dkim/provision',
        name: 'api_v1_domain_dkim_provision',
        requirements: [
            'id' => '[1-9][0-9]*',
        ],
        methods: ['POST'],
    )]
    public function provisionDkim(
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

        $domain =
            $this->findDomain(
                $id,
            );

        if (
            !$domain
            instanceof SendingDomain
        ) {
            return self::error(
                'domain_not_found',
                'Sending domain was not found.',
                Response::HTTP_NOT_FOUND,
            );
        }

        if (
            $domain->getStatus()
            !== SendingDomainStatus::VERIFIED
        ) {
            return self::error(
                'domain_not_verified',
                'DKIM can only be provisioned for a verified sending domain.',
                Response::HTTP_CONFLICT,
            );
        }

        $document =
            self::serializeDomain(
                $domain,
            );

        if (
            $domain->isDkimReady()
        ) {
            $document['dkimProvisioningQueued'] =
                false;

            return new JsonResponse(
                $document,
                Response::HTTP_OK,
            );
        }

        $domainId =
            $domain->getId();

        if (
            !is_int(
                $domainId,
            )
            || $domainId < 1
        ) {
            throw new RuntimeException(
                'Persisted sending domain has no valid identifier.',
            );
        }

        $this
            ->messageBus
            ->dispatch(
                new ProvisionSendingDomainDkim(
                    $domainId,
                ),
            );

        $document['dkimProvisioningQueued'] =
            true;

        return new JsonResponse(
            $document,
            Response::HTTP_ACCEPTED,
        );
    }

    private function findDomain(
        string $id,
    ): ?SendingDomain {
        $domainId =
            filter_var(
                $id,
                FILTER_VALIDATE_INT,
                [
                    'options' => [
                        'min_range' => 1,
                    ],
                ],
            );

        if (!is_int($domainId)) {
            return null;
        }

        $domain =
            $this
                ->entityManager
                ->find(
                    SendingDomain::class,
                    $domainId,
                );

        return $domain
            instanceof SendingDomain
            ? $domain
            : null;
    }

    /**
     * @return array{
     *     id: int,
     *     domain: string,
     *     status: string,
     *     verification: array{
     *         type: string,
     *         name: string,
     *         value: string
     *     },
     *     dkim: array{
     *         ready: bool,
     *         selector: ?string,
     *         type: string,
     *         name: ?string,
     *         value: ?string,
     *         provisionedAt: ?string
     *     },
     *     createdAt: string,
     *     verificationCheckedAt: ?string,
     *     verifiedAt: ?string,
     *     disabledAt: ?string
     * }
     */
    private static function serializeDomain(
        SendingDomain $domain,
    ): array {
        $id =
            $domain->getId();

        if (
            !is_int($id)
            || $id < 1
        ) {
            throw new RuntimeException(
                'Persisted sending domain has no valid identifier.',
            );
        }

        return [
            'id' => $id,
            'domain'
                => $domain
                    ->getDomain(),
            'status'
                => $domain
                    ->getStatus()
                    ->value,
            'verification' => [
                'type' => 'TXT',
                'name'
                    => $domain
                        ->getVerificationRecordName(),
                'value'
                    => $domain
                        ->getVerificationRecordValue(),
            ],
            'dkim' => [
                'ready'
                    => $domain
                        ->isDkimReady(),
                'selector'
                    => $domain
                        ->getDkimSelector(),
                'type' => 'TXT',
                'name'
                    => $domain
                        ->getDkimRecordName(),
                'value'
                    => $domain
                        ->getDkimRecordValue(),
                'provisionedAt'
                    => $domain
                        ->getDkimProvisionedAt()
                        ?->format(DATE_ATOM),
            ],
            'createdAt'
                => $domain
                    ->getCreatedAt()
                    ->format(DATE_ATOM),
            'verificationCheckedAt'
                => $domain
                    ->getVerificationCheckedAt()
                    ?->format(DATE_ATOM),
            'verifiedAt'
                => $domain
                    ->getVerifiedAt()
                    ?->format(DATE_ATOM),
            'disabledAt'
                => $domain
                    ->getDisabledAt()
                    ?->format(DATE_ATOM),
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
