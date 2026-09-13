<?php

declare(strict_types=1);

namespace App\Webhook;

use RuntimeException;

final readonly class WebhookHttpClient
{
    /**
     * @var array<string, true>
     */
    private array $privateHostAllowlist;

    public function __construct(
        private string $caFile = '',
        string $privateHostAllowlist = '',
    ) {
        $hosts = [];

        foreach (
            explode(
                ',',
                $privateHostAllowlist,
            )
            as $host
        ) {
            $host =
                strtolower(
                    trim(
                        $host,
                    ),
                );

            if ($host === '') {
                continue;
            }

            if (
                filter_var(
                    $host,
                    FILTER_VALIDATE_DOMAIN,
                    FILTER_FLAG_HOSTNAME,
                ) === false
            ) {
                throw new RuntimeException(
                    'Invalid private webhook host allowlist.',
                );
            }

            $hosts[$host] = true;
        }

        $this->privateHostAllowlist =
            $hosts;
    }

    public function post(
        string $url,
        string $webhookId,
        WebhookRequest $request,
    ): int {
        $parts =
            parse_url(
                $url,
            );

        if (
            !is_array($parts)
            || strtolower(
                (string) (
                    $parts['scheme']
                    ?? ''
                ),
            ) !== 'https'
            || !isset($parts['host'])
        ) {
            throw new RuntimeException(
                'Invalid HTTPS webhook URL.',
            );
        }

        $host =
            strtolower(
                (string) $parts['host'],
            );

        $port =
            isset($parts['port'])
                ? (int) $parts['port']
                : 443;

        if (
            $port < 1
            || $port > 65535
        ) {
            throw new RuntimeException(
                'Invalid webhook port.',
            );
        }

        $ips =
            $this->resolvePublicAddresses(
                $host,
            );

        if ($ips === []) {
            throw new RuntimeException(
                'Webhook hostname has no allowed address.',
            );
        }

        $path =
            $parts['path']
            ?? '/';

        if ($path === '') {
            $path = '/';
        }

        if (
            isset($parts['query'])
            && $parts['query'] !== ''
        ) {
            $path .=
                '?'
                . $parts['query'];
        }

        $lastError =
            'Unable to connect to webhook endpoint.';

        foreach ($ips as $ip) {
            try {
                return $this->postToAddress(
                    host: $host,
                    ip: $ip,
                    port: $port,
                    path: $path,
                    webhookId: $webhookId,
                    request: $request,
                );
            } catch (RuntimeException $exception) {
                $lastError =
                    $exception->getMessage();
            }
        }

        throw new RuntimeException(
            $lastError,
        );
    }

    /**
     * @return list<string>
     */
    private function resolvePublicAddresses(
        string $host,
    ): array {
        if (
            filter_var(
                $host,
                FILTER_VALIDATE_IP,
            ) !== false
        ) {
            /*
             * Literal private IPs are never allowlisted.
             */
            return self::isAllowedAddress(
                $host,
                false,
            )
                ? [$host]
                : [];
        }

        $allowPrivate =
            isset(
                $this
                    ->privateHostAllowlist[
                        $host
                    ],
            );

        $records =
            dns_get_record(
                $host,
                DNS_A
                | DNS_AAAA,
            );

        if (!is_array($records)) {
            return [];
        }

        $addresses = [];

        foreach ($records as $record) {
            $ip =
                $record['ip']
                ?? $record['ipv6']
                ?? null;

            if (
                !is_string($ip)
                || !self::isAllowedAddress(
                    $ip,
                    $allowPrivate,
                )
            ) {
                continue;
            }

            $addresses[$ip] = true;
        }

        return array_keys(
            $addresses,
        );
    }

    private static function isAllowedAddress(
        string $ip,
        bool $allowPrivate,
    ): bool {
        $flags =
            FILTER_FLAG_NO_RES_RANGE;

        if (!$allowPrivate) {
            $flags |=
                FILTER_FLAG_NO_PRIV_RANGE;
        }

        return filter_var(
            $ip,
            FILTER_VALIDATE_IP,
            $flags,
        ) !== false;
    }

    private function postToAddress(
        string $host,
        string $ip,
        int $port,
        string $path,
        string $webhookId,
        WebhookRequest $request,
    ): int {
        $ssl = [
            'verify_peer' => true,
            'verify_peer_name' => true,
            'peer_name' => $host,
            'SNI_enabled' => true,
            'SNI_server_name' => $host,
            'disable_compression' => true,
        ];

        if ($this->caFile !== '') {
            $ssl['cafile'] =
                $this->caFile;
        }

        $context =
            stream_context_create([
                'ssl' => $ssl,
            ]);

        $address =
            str_contains(
                $ip,
                ':',
            )
                ? '[' . $ip . ']'
                : $ip;

        $errno = 0;
        $error = '';

        $socket =
            @stream_socket_client(
                sprintf(
                    'tls://%s:%d',
                    $address,
                    $port,
                ),
                $errno,
                $error,
                5.0,
                STREAM_CLIENT_CONNECT,
                $context,
            );

        if ($socket === false) {
            throw new RuntimeException(
                sprintf(
                    'Webhook TLS connection failed (%d).',
                    $errno,
                ),
            );
        }

        try {
            stream_set_timeout(
                $socket,
                10,
            );

            $hostHeader =
                $port === 443
                    ? $host
                    : sprintf(
                        '%s:%d',
                        $host,
                        $port,
                    );

            $headers = [
                sprintf(
                    'POST %s HTTP/1.1',
                    $path,
                ),
                'Host: ' . $hostHeader,
                'Content-Type: application/json',
                'Connection: close',
                'User-Agent: HeyMail-Webhooks/1',
                'X-HeyMail-Webhook-Id: '
                    . $webhookId,
                'X-HeyMail-Webhook-Timestamp: '
                    . $request->timestamp,
                'X-HeyMail-Webhook-Signature: '
                    . $request->signature,
                'Content-Length: '
                    . strlen(
                        $request->body,
                    ),
                '',
                $request->body,
            ];

            $wire =
                implode(
                    "\r\n",
                    $headers,
                );

            $length =
                strlen(
                    $wire,
                );

            $offset = 0;

            while ($offset < $length) {
                $written =
                    fwrite(
                        $socket,
                        substr(
                            $wire,
                            $offset,
                        ),
                    );

                if (
                    $written === false
                    || $written === 0
                ) {
                    throw new RuntimeException(
                        'Unable to write complete webhook request.',
                    );
                }

                $offset +=
                    $written;
            }

            $statusLine =
                fgets(
                    $socket,
                    8192,
                );

            if (
                !is_string($statusLine)
                || preg_match(
                    '#^HTTP/1\.[01] ([0-9]{3}) #',
                    $statusLine,
                    $match,
                ) !== 1
            ) {
                throw new RuntimeException(
                    'Invalid webhook HTTP response.',
                );
            }

            return (int) $match[1];
        } finally {
            fclose(
                $socket,
            );
        }
    }
}
