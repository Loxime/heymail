<?php

declare(strict_types=1);

namespace App\Dns;

use App\Mail\DomainName;
use Doctrine\DBAL\Connection;
use RuntimeException;

final class OvhDnsPublisher
{
    private string $zone;

    public function __construct(
        private readonly Connection $connection,
        private readonly OvhApiClient $client,
        string $zone,
    ) {
        $this->zone =
            (
                new DomainName(
                    $zone,
                )
            )->value;
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
