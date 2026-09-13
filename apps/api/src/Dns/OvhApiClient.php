<?php

declare(strict_types=1);

namespace App\Dns;

use JsonException;
use RuntimeException;

final class OvhApiClient
{
    private const string ENDPOINT =
        'https://eu.api.ovh.com/1.0';

    private ?int $clockOffset = null;

    public function __construct(
        private readonly string $applicationKeyFile,
        private readonly string $applicationSecretFile,
        private readonly string $consumerKeyFile,
    ) {
    }

    public function syncTxtRecord(
        string $zone,
        string $subDomain,
        string $target,
    ): string {
        return $this->syncRecord(
            $zone,
            'TXT',
            $subDomain,
            $target,
        );
    }

    public function syncARecord(
        string $zone,
        string $subDomain,
        string $target,
    ): string {
        return $this->syncRecord(
            $zone,
            'A',
            $subDomain,
            $target,
        );
    }

    public function syncMxRecord(
        string $zone,
        string $subDomain,
        string $target,
    ): string {
        return $this->syncRecord(
            $zone,
            'MX',
            $subDomain,
            $target,
        );
    }

    private function syncRecord(
        string $zone,
        string $fieldType,
        string $subDomain,
        string $target,
    ): string {
        if (
            !in_array(
                $fieldType,
                [
                    'TXT',
                    'A',
                    'MX',
                ],
                true,
            )
        ) {
            throw new RuntimeException(
                'Refusing unsupported DNS record type.',
            );
        }

        $basePath = sprintf(
            '/domain/zone/%s/record',
            rawurlencode($zone),
        );

        $ids = $this->request(
            'GET',
            $basePath
            . '?fieldType='
            . rawurlencode($fieldType)
            . '&subDomain='
            . rawurlencode($subDomain),
        );

        if (!is_array($ids)) {
            throw new RuntimeException(
                'OVH returned an invalid record list.',
            );
        }

        if (count($ids) > 1) {
            throw new RuntimeException(
                sprintf(
                    'Refusing ambiguous %s record: %s',
                    $fieldType,
                    $subDomain,
                ),
            );
        }

        if ($ids === []) {
            $this->request(
                'POST',
                $basePath,
                [
                    'fieldType' => $fieldType,
                    'subDomain' => $subDomain,
                    'target' => $target,
                    'ttl' => 60,
                ],
            );

            return 'created';
        }

        $recordId = $ids[0];

        if (
            !is_int($recordId)
            && !is_string($recordId)
        ) {
            throw new RuntimeException(
                'OVH returned an invalid record identifier.',
            );
        }

        $record = $this->request(
            'GET',
            $basePath
            . '/'
            . rawurlencode(
                (string) $recordId,
            ),
        );

        if (
            !is_array($record)
            || !isset($record['target'])
            || !is_string($record['target'])
        ) {
            throw new RuntimeException(
                'OVH returned an invalid DNS record.',
            );
        }

        $equivalent = match ($fieldType) {
            'TXT' => self::txtTargetsEquivalent(
                $record['target'],
                $target,
            ),

            'MX' => strtolower(
                rtrim(
                    trim($record['target']),
                    '.',
                ),
            ) === strtolower(
                rtrim(
                    trim($target),
                    '.',
                ),
            ),

            default => hash_equals(
                $record['target'],
                $target,
            ),
        };

        if ($equivalent) {
            return 'unchanged';
        }

        $this->request(
            'PUT',
            $basePath
            . '/'
            . rawurlencode(
                (string) $recordId,
            ),
            [
                'target' => $target,
            ],
        );

        return 'updated';
    }

    public function refreshZone(
        string $zone,
    ): void {
        $this->request(
            'POST',
            sprintf(
                '/domain/zone/%s/refresh',
                rawurlencode($zone),
            ),
            [],
        );
    }

    /**
     * @param array<string, mixed>|null $payload
     */
    private function request(
        string $method,
        string $path,
        ?array $payload = null,
        bool $signed = true,
    ): mixed {
        if (
            $path !== '/auth/time'
            && !str_starts_with(
                $path,
                '/domain/zone/',
            )
        ) {
            throw new RuntimeException(
                'Refusing unexpected OVH API path.',
            );
        }

        $url =
            self::ENDPOINT
            . $path;

        try {
            $body =
                $payload === null
                    ? ''
                    : json_encode(
                        $payload,
                        JSON_THROW_ON_ERROR
                        | JSON_UNESCAPED_SLASHES,
                    );
        } catch (JsonException $exception) {
            throw new RuntimeException(
                'Unable to encode OVH request.',
                0,
                $exception,
            );
        }

        $headers = [
            'Accept: application/json',
        ];

        if ($payload !== null) {
            $headers[] =
                'Content-Type: application/json';
        }

        if ($signed) {
            $applicationKey =
                self::readSecret(
                    $this->applicationKeyFile,
                    'OVH application key',
                );

            $applicationSecret =
                self::readSecret(
                    $this->applicationSecretFile,
                    'OVH application secret',
                );

            $consumerKey =
                self::readSecret(
                    $this->consumerKeyFile,
                    'OVH consumer key',
                );

            $timestamp =
                $this->signedTimestamp();

            $signature =
                '$1$'
                . sha1(
                    $applicationSecret
                    . '+'
                    . $consumerKey
                    . '+'
                    . $method
                    . '+'
                    . $url
                    . '+'
                    . $body
                    . '+'
                    . $timestamp,
                );

            $headers[] =
                'X-Ovh-Application: '
                . $applicationKey;

            $headers[] =
                'X-Ovh-Consumer: '
                . $consumerKey;

            $headers[] =
                'X-Ovh-Signature: '
                . $signature;

            $headers[] =
                'X-Ovh-Timestamp: '
                . $timestamp;
        }

        $http = [
            'method' => $method,
            'header' => implode(
                "\r\n",
                $headers,
            ),
            'timeout' => 10,
            'ignore_errors' => true,
            'follow_location' => 0,
        ];

        if ($body !== '') {
            $http['content'] = $body;
        }

        $context =
            stream_context_create([
                'http' => $http,
                'ssl' => [
                    'verify_peer' => true,
                    'verify_peer_name' => true,
                ],
            ]);

        $response =
            @file_get_contents(
                $url,
                false,
                $context,
            );

        $responseHeaders =
            $http_response_header
            ?? [];

        $status =
            self::statusCode(
                $responseHeaders,
            );

        if (
            $response === false
            && $status === null
        ) {
            throw new RuntimeException(
                'Unable to reach OVH API.',
            );
        }

        if (
            $status === null
            || $status < 200
            || $status >= 300
        ) {
            throw new RuntimeException(
                sprintf(
                    'OVH API request failed with HTTP %s.',
                    $status === null
                        ? 'unknown'
                        : (string) $status,
                ),
            );
        }

        if (
            $status === 204
            || $response === ''
        ) {
            return null;
        }

        try {
            return json_decode(
                $response,
                true,
                512,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException $exception) {
            throw new RuntimeException(
                'OVH returned invalid JSON.',
                0,
                $exception,
            );
        }
    }

    private static function txtTargetsEquivalent(
        string $actual,
        string $expected,
    ): bool {
        if (
            hash_equals(
                $actual,
                $expected,
            )
        ) {
            return true;
        }

        $logical =
            self::decodeTxtPresentation(
                $actual,
            );

        return $logical !== null
            && hash_equals(
                $logical,
                $expected,
            );
    }

    /*
     * OVH may canonicalize TXT targets as DNS master-file
     * presentation strings:
     *
     *     "short value"
     *
     * or, for long DKIM records:
     *
     *     "first chunk" "second chunk"
     *
     * Convert that representation back to the logical TXT value
     * before comparing it with HeyMail's desired value.
     */
    private static function decodeTxtPresentation(
        string $value,
    ): ?string {
        $value = trim($value);
        $length = strlen($value);

        if (
            $length < 2
            || $value[0] !== '"'
        ) {
            return null;
        }

        $result = '';
        $offset = 0;
        $chunks = 0;

        while ($offset < $length) {
            while (
                $offset < $length
                && ctype_space(
                    $value[$offset],
                )
            ) {
                ++$offset;
            }

            if ($offset >= $length) {
                break;
            }

            if ($value[$offset] !== '"') {
                return null;
            }

            ++$offset;
            ++$chunks;

            $closed = false;

            while ($offset < $length) {
                $character =
                    $value[$offset];

                ++$offset;

                if ($character === '"') {
                    $closed = true;

                    break;
                }

                if ($character !== '\\') {
                    $result .= $character;

                    continue;
                }

                if ($offset >= $length) {
                    return null;
                }

                if (
                    $offset + 2 < $length
                    && ctype_digit(
                        $value[$offset],
                    )
                    && ctype_digit(
                        $value[$offset + 1],
                    )
                    && ctype_digit(
                        $value[$offset + 2],
                    )
                ) {
                    $decimal =
                        (int) substr(
                            $value,
                            $offset,
                            3,
                        );

                    if ($decimal > 255) {
                        return null;
                    }

                    $result .= chr($decimal);
                    $offset += 3;

                    continue;
                }

                $result .=
                    $value[$offset];

                ++$offset;
            }

            if (!$closed) {
                return null;
            }
        }

        return $chunks > 0
            ? $result
            : null;
    }

    private function signedTimestamp(): int
    {
        if ($this->clockOffset === null) {
            $serverTime =
                $this->request(
                    'GET',
                    '/auth/time',
                    null,
                    false,
                );

            if (
                !is_int($serverTime)
                && !(
                    is_string($serverTime)
                    && ctype_digit($serverTime)
                )
            ) {
                throw new RuntimeException(
                    'OVH returned invalid server time.',
                );
            }

            $this->clockOffset =
                (int) $serverTime
                - time();
        }

        return time()
            + $this->clockOffset;
    }

    /**
     * @param list<string> $headers
     */
    private static function statusCode(
        array $headers,
    ): ?int {
        $status = null;

        foreach ($headers as $header) {
            if (
                preg_match(
                    '/^HTTP\/\S+\s+([1-5][0-9]{2})\b/',
                    $header,
                    $matches,
                ) === 1
            ) {
                $status =
                    (int) $matches[1];
            }
        }

        return $status;
    }

    private static function readSecret(
        string $path,
        string $label,
    ): string {
        $value =
            @file_get_contents(
                $path,
            );

        if ($value === false) {
            throw new RuntimeException(
                sprintf(
                    'Unable to read %s.',
                    $label,
                ),
            );
        }

        $value = trim($value);

        if ($value === '') {
            throw new RuntimeException(
                sprintf(
                    '%s is empty.',
                    $label,
                ),
            );
        }

        return $value;
    }
}
