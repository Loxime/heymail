<?php

declare(strict_types=1);

namespace App\Console;

use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

final readonly class ConsoleRequestGuard
{
    public function rejectCrossOriginMutation(
        Request $request,
    ): ?JsonResponse {
        $fetchSite = strtolower(
            trim(
                (string) $request->headers->get(
                    'Sec-Fetch-Site',
                    '',
                ),
            ),
        );

        if (
            $fetchSite !== ''
            && $fetchSite !== 'same-origin'
        ) {
            return self::forbidden();
        }

        $origin = $request->headers->get(
            'Origin',
        );

        if ($origin === null) {
            return null;
        }

        $origin = trim($origin);

        if ($origin === '') {
            return null;
        }

        $actual = self::normalizeOrigin(
            $origin,
        );

        $expected = self::normalizeOrigin(
            $request->getSchemeAndHttpHost(),
        );

        if (
            $actual === null
            || $expected === null
            || !hash_equals(
                $expected,
                $actual,
            )
        ) {
            return self::forbidden();
        }

        return null;
    }

    private static function normalizeOrigin(
        string $origin,
    ): ?string {
        $parts = parse_url($origin);

        if (
            !is_array($parts)
            || !isset(
                $parts['scheme'],
                $parts['host'],
            )
            || !is_string($parts['scheme'])
            || !is_string($parts['host'])
        ) {
            return null;
        }

        $scheme = strtolower(
            $parts['scheme'],
        );

        if (
            $scheme !== 'https'
            && $scheme !== 'http'
        ) {
            return null;
        }

        $host = strtolower(
            $parts['host'],
        );

        $port = $parts['port']
            ?? null;

        if (
            $port === null
            || (
                $scheme === 'https'
                && $port === 443
            )
            || (
                $scheme === 'http'
                && $port === 80
            )
        ) {
            return sprintf(
                '%s://%s',
                $scheme,
                $host,
            );
        }

        return sprintf(
            '%s://%s:%d',
            $scheme,
            $host,
            $port,
        );
    }

    private static function forbidden(): JsonResponse
    {
        return new JsonResponse(
            [
                'error' => [
                    'code'
                        => 'console_cross_origin_rejected',
                    'message'
                        => 'Cross-origin console mutation rejected.',
                ],
            ],
            Response::HTTP_FORBIDDEN,
        );
    }
}
