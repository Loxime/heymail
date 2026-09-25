<?php

declare(strict_types=1);

namespace App\Dns;

use App\Mail\DomainName;
use Doctrine\DBAL\Connection;
use RuntimeException;

final class OvhDnsPublisher
{
    private string $zone;
    private string $consoleDomain;
    private string $inboundDomain;
    private string $srsDomain;
    private string $bounceDomain;
    private string $publicIpv4;

    public function __construct(
        private readonly Connection $connection,
        private readonly OvhApiClient $client,
        string $zone,
        string $consoleDomain,
        string $inboundDomain,
        string $srsDomain,
        string $bounceDomain,
        string $publicIpv4,
    ) {
        $this->zone =
            (
                new DomainName(
                    $zone,
                )
            )->value;

        $this->consoleDomain =
            (
                new DomainName(
                    $consoleDomain,
                )
            )->value;

        $this->inboundDomain =
            (
                new DomainName(
                    $inboundDomain,
                )
            )->value;

        $this->srsDomain =
            (
                new DomainName(
                    $srsDomain,
                )
            )->value;

        $this->bounceDomain =
            (
                new DomainName(
                    $bounceDomain,
                )
            )->value;

        if (
            !$this->isManagedDomain(
                $this->consoleDomain,
            )
        ) {
            throw new RuntimeException(
                'Console domain is outside managed zone.',
            );
        }

        if (
            !$this->isManagedDomain(
                $this->inboundDomain,
            )
        ) {
            throw new RuntimeException(
                'Inbound domain is outside managed zone.',
            );
        }

        if (
            !$this->isManagedDomain(
                $this->srsDomain,
            )
        ) {
            throw new RuntimeException(
                'SRS domain is outside managed zone.',
            );
        }

        if (
            $this->srsDomain
            === $this->inboundDomain
            || $this->srsDomain
            === $this->bounceDomain
        ) {
            throw new RuntimeException(
                'SRS domain must be dedicated.',
            );
        }

        if (
            !$this->isManagedDomain(
                $this->bounceDomain,
            )
        ) {
            throw new RuntimeException(
                'Bounce domain is outside managed zone.',
            );
        }

        if (
            filter_var(
                $publicIpv4,
                FILTER_VALIDATE_IP,
                FILTER_FLAG_IPV4,
            ) === false
        ) {
            throw new RuntimeException(
                'Invalid public IPv4 address.',
            );
        }

        $this->publicIpv4 = $publicIpv4;
    }

    /**
     * @return list<array{
     *     record: string,
     *     action: string
     * }>
     */
    public function publish(): array
    {
        $rows =
            $this->connection
                ->fetchAllAssociative(
                    <<<'SQL'
SELECT
    domain,
    verification_token,
    dkim_selector,
    dkim_public_key,
    dkim_provisioned_at
FROM sending_domain
WHERE status <> 'disabled'
ORDER BY id ASC
SQL
                );

        $results = [];
        $changed = false;

        $action =
            $this->client
                ->syncARecord(
                    $this->zone,
                    $this->relativeName(
                        $this->consoleDomain,
                    ),
                    $this->publicIpv4,
                );

        $results[] = [
            'record'
                => 'A '
                . $this->consoleDomain,
            'action' => $action,
        ];

        if ($action !== 'unchanged') {
            $changed = true;
        }

        if (
            $this->inboundDomain
            !== $this->consoleDomain
        ) {
            $action =
                $this->client
                    ->syncARecord(
                        $this->zone,
                        $this->relativeName(
                            $this->inboundDomain,
                        ),
                        $this->publicIpv4,
                    );

            $results[] = [
                'record'
                    => 'A '
                    . $this->inboundDomain,
                'action' => $action,
            ];

            if ($action !== 'unchanged') {
                $changed = true;
            }
        }

        $action =
            $this->client
                ->syncMxRecord(
                    $this->zone,
                    $this->relativeName(
                        $this->inboundDomain,
                    ),
                    '10 '
                    . $this->inboundDomain
                    . '.',
                );

        $results[] = [
            'record'
                => 'MX '
                . $this->inboundDomain,
            'action' => $action,
        ];

        if ($action !== 'unchanged') {
            $changed = true;
        }

        $action =
            $this->client
                ->syncARecord(
                    $this->zone,
                    $this->relativeName(
                        $this->srsDomain,
                    ),
                    $this->publicIpv4,
                );

        $results[] = [
            'record'
                => 'A '
                . $this->srsDomain,
            'action' => $action,
        ];

        if ($action !== 'unchanged') {
            $changed = true;
        }

        $action =
            $this->client
                ->syncMxRecord(
                    $this->zone,
                    $this->relativeName(
                        $this->srsDomain,
                    ),
                    '10 '
                    . $this->srsDomain
                    . '.',
                );

        $results[] = [
            'record'
                => 'MX '
                . $this->srsDomain,
            'action' => $action,
        ];

        if ($action !== 'unchanged') {
            $changed = true;
        }

        $action =
            $this->client
                ->syncTxtRecord(
                    $this->zone,
                    $this->relativeName(
                        $this->srsDomain,
                    ),
                    'v=spf1 ip4:'
                    . $this->publicIpv4
                    . ' -all',
                );

        $results[] = [
            'record'
                => 'TXT '
                . $this->srsDomain,
            'action' => $action,
        ];

        if ($action !== 'unchanged') {
            $changed = true;
        }

        $action =
            $this->client
                ->syncARecord(
                    $this->zone,
                    $this->relativeName(
                        $this->bounceDomain,
                    ),
                    $this->publicIpv4,
                );

        $results[] = [
            'record'
                => 'A '
                . $this->bounceDomain,
            'action' => $action,
        ];

        if ($action !== 'unchanged') {
            $changed = true;
        }

        $action =
            $this->client
                ->syncMxRecord(
                    $this->zone,
                    $this->relativeName(
                        $this->bounceDomain,
                    ),
                    '10 '
                    . $this->bounceDomain
                    . '.',
                );

        $results[] = [
            'record'
                => 'MX '
                . $this->bounceDomain,
            'action' => $action,
        ];

        if ($action !== 'unchanged') {
            $changed = true;
        }

        foreach ($rows as $row) {
            $domainRaw =
                $row['domain']
                ?? null;

            if (!is_string($domainRaw)) {
                throw new RuntimeException(
                    'Invalid sending domain row.',
                );
            }

            $domain =
                (
                    new DomainName(
                        $domainRaw,
                    )
                )->value;

            if (
                !$this->isManagedDomain(
                    $domain,
                )
            ) {
                $results[] = [
                    'record' => $domain,
                    'action'
                        => 'skipped_outside_zone',
                ];

                continue;
            }

            $token =
                $row['verification_token']
                ?? null;

            if (
                !is_string($token)
                || preg_match(
                    '/^[a-f0-9]{64}$/D',
                    $token,
                ) !== 1
            ) {
                throw new RuntimeException(
                    'Invalid verification token.',
                );
            }

            $verificationFqdn =
                '_heymail-verification.'
                . $domain;

            $action =
                $this->client
                    ->syncTxtRecord(
                        $this->zone,
                        $this->relativeName(
                            $verificationFqdn,
                        ),
                        'heymail-verification='
                        . $token,
                    );

            $results[] = [
                'record'
                    => $verificationFqdn,
                'action' => $action,
            ];

            if ($action !== 'unchanged') {
                $changed = true;
            }

            $selector =
                $row['dkim_selector']
                ?? null;

            $publicKey =
                $row['dkim_public_key']
                ?? null;

            $provisionedAt =
                $row['dkim_provisioned_at']
                ?? null;

            $hasAnyDkim =
                $selector !== null
                || $publicKey !== null
                || $provisionedAt !== null;

            $hasAllDkim =
                is_string($selector)
                && is_string($publicKey)
                && $provisionedAt !== null;

            if (
                $hasAnyDkim
                && !$hasAllDkim
            ) {
                throw new RuntimeException(
                    sprintf(
                        'Incomplete DKIM state for %s.',
                        $domain,
                    ),
                );
            }

            if (!$hasAllDkim) {
                continue;
            }

            if (
                preg_match(
                    '/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D',
                    $selector,
                ) !== 1
                || $publicKey === ''
                || base64_decode(
                    $publicKey,
                    true,
                ) === false
            ) {
                throw new RuntimeException(
                    sprintf(
                        'Invalid DKIM state for %s.',
                        $domain,
                    ),
                );
            }

            $dkimFqdn =
                $selector
                . '._domainkey.'
                . $domain;

            $action =
                $this->client
                    ->syncTxtRecord(
                        $this->zone,
                        $this->relativeName(
                            $dkimFqdn,
                        ),
                        'v=DKIM1; k=rsa; p='
                        . $publicKey,
                    );

            $results[] = [
                'record' => $dkimFqdn,
                'action' => $action,
            ];

            if ($action !== 'unchanged') {
                $changed = true;
            }
        }

        if ($changed) {
            $this->client
                ->refreshZone(
                    $this->zone,
                );
        }

        return $results;
    }

    private function isManagedDomain(
        string $domain,
    ): bool {
        return $domain === $this->zone
            || str_ends_with(
                $domain,
                '.'
                . $this->zone,
            );
    }

    private function relativeName(
        string $fqdn,
    ): string {
        if ($fqdn === $this->zone) {
            return '';
        }

        $suffix =
            '.'
            . $this->zone;

        if (
            !str_ends_with(
                $fqdn,
                $suffix,
            )
        ) {
            throw new RuntimeException(
                'Refusing DNS record outside managed zone.',
            );
        }

        return substr(
            $fqdn,
            0,
            -strlen($suffix),
        );
    }
}
