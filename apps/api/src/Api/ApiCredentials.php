<?php

declare(strict_types=1);

namespace App\Api;

use App\Workspace\LegacyApiWorkspace;
use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use RuntimeException;
use Symfony\Component\HttpFoundation\Request;

final class ApiCredentials
{
    private string $apiKey;
    private string $apiSecret;

    public function __construct(
        string $apiKeyFile,
        string $apiSecretFile,
        private readonly ?LegacyApiWorkspace $legacyApiWorkspace = null,
        private readonly ?Connection $connection = null,
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
        return $this
            ->authorizedKeyFingerprint(
                $request,
            ) !== null;
    }

    public function authorizedPrincipal(
        Request $request,
    ): ?ApiPrincipal {
        $match = $this->credentialMatch(
            $request,
        );

        if ($match === null) {
            return null;
        }

        $workspaceId = $match['workspaceId'];

        if ($workspaceId === null) {
            if ($this->legacyApiWorkspace === null) {
                throw new RuntimeException(
                    'API workspace resolver is unavailable.',
                );
            }

            $workspaceId =
                $this
                    ->legacyApiWorkspace
                    ->id();
        }

        return new ApiPrincipal(
            keyFingerprint: $match['fingerprint'],
            workspaceId: $workspaceId,
        );
    }

    public function authorizedKeyFingerprint(
        Request $request,
    ): ?string {
        $match = $this->credentialMatch(
            $request,
        );

        return $match['fingerprint']
            ?? null;
    }

    /**
     * @return array{
     *     fingerprint: string,
     *     workspaceId: int|null
     * }|null
     */
    private function credentialMatch(
        Request $request,
    ): ?array {
        $parsed = self::parseBasicCredentials(
            $request,
        );

        if ($parsed === null) {
            return null;
        }

        [
            $providedKey,
            $providedSecret,
        ] = $parsed;

        if (
            preg_match(
                '/^hm_[a-f0-9]{32}$/D',
                $providedKey,
            ) !== 1
            || preg_match(
                '/^[a-f0-9]{64}$/D',
                $providedSecret,
            ) !== 1
        ) {
            return null;
        }

        if ($this->connection !== null) {
            $row =
                $this
                    ->connection
                    ->fetchAssociative(
                        <<<'SQL'
SELECT
    id,
    workspace_id,
    key_fingerprint,
    secret_hash,
    revoked_at
FROM api_credential
WHERE api_key = :api_key
SQL,
                        [
                            'api_key'
                                => $providedKey,
                        ],
                    );

            /*
             * A persisted key is authoritative. A revoked key or a wrong
             * secret must never fall through to the legacy file-backed pair.
             */
            if ($row !== false) {
                if (
                    $row['revoked_at'] !== null
                    || !is_string(
                        $row['secret_hash']
                        ?? null,
                    )
                    || !password_verify(
                        $providedSecret,
                        $row['secret_hash'],
                    )
                ) {
                    return null;
                }

                $workspaceId = self::positiveId(
                    $row['workspace_id']
                    ?? null,
                    'API credential workspace',
                );

                $credentialId = self::positiveId(
                    $row['id']
                    ?? null,
                    'API credential',
                );

                $fingerprint =
                    $row['key_fingerprint']
                    ?? null;

                $expectedFingerprint = hash(
                    'sha256',
                    $providedKey,
                );

                if (
                    !is_string($fingerprint)
                    || preg_match(
                        '/^[a-f0-9]{64}$/D',
                        $fingerprint,
                    ) !== 1
                    || !hash_equals(
                        $expectedFingerprint,
                        $fingerprint,
                    )
                ) {
                    throw new RuntimeException(
                        'API credential fingerprint is invalid.',
                    );
                }

                $this
                    ->connection
                    ->executeStatement(
                        <<<'SQL'
UPDATE api_credential
SET last_used_at = :last_used_at
WHERE id = :id
  AND revoked_at IS NULL
SQL,
                        [
                            'last_used_at'
                                => self::now()
                                    ->format(
                                        'Y-m-d H:i:s',
                                    ),
                            'id'
                                => $credentialId,
                        ],
                    );

                return [
                    'fingerprint'
                        => $fingerprint,
                    'workspaceId'
                        => $workspaceId,
                ];
            }
        }

        if (
            !hash_equals(
                $this->apiKey,
                $providedKey,
            )
            || !hash_equals(
                $this->apiSecret,
                $providedSecret,
            )
        ) {
            return null;
        }

        return [
            'fingerprint'
                => hash(
                    'sha256',
                    $providedKey,
                ),
            'workspaceId'
                => null,
        ];
    }

    /**
     * @return array{string, string}|null
     */
    private static function parseBasicCredentials(
        Request $request,
    ): ?array {
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
            return null;
        }

        $decoded = base64_decode(
            substr(
                $authorization,
                6,
            ),
            true,
        );

        if (!is_string($decoded)) {
            return null;
        }

        $separator = strpos(
            $decoded,
            ':',
        );

        if ($separator === false) {
            return null;
        }

        return [
            substr(
                $decoded,
                0,
                $separator,
            ),
            substr(
                $decoded,
                $separator + 1,
            ),
        ];
    }

    private static function positiveId(
        mixed $value,
        string $label,
    ): int {
        $id = filter_var(
            $value,
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        if (!is_int($id)) {
            throw new RuntimeException(
                sprintf(
                    '%s has an invalid identifier.',
                    $label,
                ),
            );
        }

        return $id;
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

    private static function now(): DateTimeImmutable
    {
        return new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );
    }
}
