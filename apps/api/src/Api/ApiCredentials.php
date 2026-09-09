<?php

declare(strict_types=1);

namespace App\Api;

use RuntimeException;
use Symfony\Component\HttpFoundation\Request;

final class ApiCredentials
{
    private string $apiKey;
    private string $apiSecret;

    public function __construct(
        string $apiKeyFile,
        string $apiSecretFile,
    ) {
        $this->apiKey = self::readSecret(
            $apiKeyFile,
            'API key',
        );

        $this->apiSecret = self::readSecret(
            $apiSecretFile,
            'API secret',
        );

        if (
            preg_match(
                '/^hm_[a-f0-9]{32}$/D',
                $this->apiKey,
            ) !== 1
        ) {
            throw new RuntimeException(
                'HeyMail API key has an invalid format.',
            );
        }

        if (
            preg_match(
                '/^[a-f0-9]{64}$/D',
                $this->apiSecret,
            ) !== 1
        ) {
            throw new RuntimeException(
                'HeyMail API secret has an invalid format.',
            );
        }
    }

    public function authorizes(
        Request $request,
    ): bool {
        $authorization = $request
            ->headers
            ->get('Authorization');

        if (
            !is_string($authorization)
            || strlen($authorization) > 1024
            || strncasecmp(
                $authorization,
                'Basic ',
                6,
            ) !== 0
        ) {
            return false;
        }

        $decoded = base64_decode(
            substr(
                $authorization,
                6,
            ),
            true,
        );

        if (!is_string($decoded)) {
            return false;
        }

        $separator = strpos(
            $decoded,
            ':',
        );

        if ($separator === false) {
            return false;
        }

        $providedKey = substr(
            $decoded,
            0,
            $separator,
        );

        $providedSecret = substr(
            $decoded,
            $separator + 1,
        );

        return hash_equals(
            $this->apiKey,
            $providedKey,
        ) && hash_equals(
            $this->apiSecret,
            $providedSecret,
        );
    }

    private static function readSecret(
        string $path,
        string $label,
    ): string {
        $value = @file_get_contents(
            $path,
        );

        if ($value === false) {
            throw new RuntimeException(
                sprintf(
                    'Unable to read HeyMail %s.',
                    $label,
                ),
            );
        }

        $value = trim(
            $value,
        );

        if ($value === '') {
            throw new RuntimeException(
                sprintf(
                    'HeyMail %s is empty.',
                    $label,
                ),
            );
        }

        return $value;
    }
}
