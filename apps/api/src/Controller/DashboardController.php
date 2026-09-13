<?php

declare(strict_types=1);

namespace App\Controller;

use App\Api\ApiCredentials;
use App\Query\DashboardPeriod;
use App\Query\DashboardQueryService;
use InvalidArgumentException;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/api/v1/dashboard')]
final readonly class DashboardController
{
    public function __construct(
        private ApiCredentials $credentials,
        private DashboardQueryService $dashboardQuery,
    ) {
    }

    #[Route(
        '',
        name: 'api_v1_dashboard',
        methods: ['GET'],
    )]
    public function dashboard(
        Request $request,
    ): JsonResponse {
        if (
            !$this
                ->credentials
                ->authorizes(
                    $request,
                )
        ) {
            return self::unauthorized();
        }

        $query =
            $request
                ->query
                ->all();

        foreach (
            array_keys(
                $query,
            )
            as $key
        ) {
            if (
                !is_string($key)
                || !in_array(
                    $key,
                    [
                        'from',
                        'to',
                    ],
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

        try {
            $period =
                DashboardPeriod::fromQuery(
                    $query['from']
                    ?? null,
                    $query['to']
                    ?? null,
                );
        } catch (InvalidArgumentException $exception) {
            return self::error(
                'invalid_query',
                $exception->getMessage(),
                Response::HTTP_BAD_REQUEST,
            );
        }

        return new JsonResponse(
            $this
                ->dashboardQuery
                ->query(
                    $period,
                ),
        );
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
