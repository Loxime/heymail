<?php

declare(strict_types=1);

namespace App\Controller;

use App\Console\ConsoleAuthentication;
use InvalidArgumentException;
use JsonException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/console/auth')]
final readonly class ConsoleAuthController
{
    private const int MAX_REQUEST_BYTES = 8192;

    public function __construct(
        private ConsoleAuthentication $authentication,
    ) {
    }

    #[Route(
        '/login',
        name: 'console_auth_login',
        methods: ['POST'],
    )]
    public function login(
        Request $request,
    ): JsonResponse {
        $payload = self::jsonObject(
            $request,
        );

        if ($payload instanceof JsonResponse) {
            return $payload;
        }

        if (
            array_keys($payload)
            !== [
                'email',
                'password',
            ]
            || !is_string(
                $payload['email'],
            )
            || !is_string(
                $payload['password'],
            )
        ) {
            return self::error(
                'invalid_payload',
                'Expected email and password.',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        try {
            $session =
                $this->authentication
                    ->login(
                        $payload['email'],
                        $payload['password'],
                    );
        } catch (InvalidArgumentException) {
            return self::error(
                'invalid_credentials',
                'Invalid email or password.',
                Response::HTTP_UNAUTHORIZED,
            );
        }

        $response = new JsonResponse([
            'user' => $session['user'],
        ]);

        $response->headers->setCookie(
            ConsoleAuthentication::sessionCookie(
                $session['token'],
                $session['expiresAt'],
                $request->isSecure(),
            ),
        );

        return $response;
    }

    #[Route(
        '/session',
        name: 'console_auth_session',
        methods: ['GET'],
    )]
    public function session(
        Request $request,
    ): JsonResponse {
        $user =
            $this->authentication
                ->authenticate(
                    $request,
                );

        if ($user === null) {
            return self::unauthorized();
        }

        return new JsonResponse([
            'user' => $user,
        ]);
    }

    #[Route(
        '/check',
        name: 'console_auth_check',
        methods: ['GET'],
    )]
    public function check(
        Request $request,
    ): Response {
        return $this->authentication
            ->authenticate(
                $request,
            ) === null
                ? new Response(
                    '',
                    Response::HTTP_UNAUTHORIZED,
                )
                : new Response(
                    '',
                    Response::HTTP_NO_CONTENT,
                );
    }

    #[Route(
        '/logout',
        name: 'console_auth_logout',
        methods: ['POST'],
    )]
    public function logout(
        Request $request,
    ): Response {
        $this->authentication
            ->logout(
                $request,
            );

        $response = new Response(
            '',
            Response::HTTP_NO_CONTENT,
        );

        $response->headers->setCookie(
            ConsoleAuthentication::expiredCookie(
                $request->isSecure(),
            ),
        );

        return $response;
    }

    /**
     * @return array<string, mixed>|JsonResponse
     */
    private static function jsonObject(
        Request $request,
    ): array|JsonResponse {
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

        $raw = $request->getContent();

        if (
            strlen($raw)
            > self::MAX_REQUEST_BYTES
        ) {
            return self::error(
                'payload_too_large',
                'Request body is too large.',
                Response::HTTP_REQUEST_ENTITY_TOO_LARGE,
            );
        }

        try {
            $payload = json_decode(
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

        return $payload;
    }

    private static function unauthorized(): JsonResponse
    {
        return self::error(
            'console_unauthorized',
            'Console authentication required.',
            Response::HTTP_UNAUTHORIZED,
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
