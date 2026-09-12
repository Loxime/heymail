<?php

declare(strict_types=1);

namespace App\Mail;

use RuntimeException;

final readonly class DkimKeyProvisioner
{
    public function __construct(
        private string $privateDirectory,
        private string $selector,
    ) {
        if (
            $this->privateDirectory === ''
            || !str_starts_with(
                $this->privateDirectory,
                '/',
            )
        ) {
            throw new RuntimeException(
                'DKIM private directory must be an absolute path.',
            );
        }

        new DkimKeyMaterial(
            $this->selector,
            base64_encode(
                'selector-validation',
            ),
        );
    }

    public function provision(
        string $rawDomain,
    ): DkimKeyMaterial {
        $domain =
            new DomainName(
                $rawDomain,
            );

        if (
            is_link(
                $this->privateDirectory,
            )
            || !is_dir(
                $this->privateDirectory,
            )
        ) {
            throw new RuntimeException(
                'DKIM private directory is invalid.',
            );
        }

        if (
            !is_writable(
                $this->privateDirectory,
            )
        ) {
            throw new RuntimeException(
                'DKIM private directory is not writable.',
            );
        }

        $domainDirectory =
            $this->domainDirectory(
                $domain->value,
            );

        $this->ensureDomainDirectory(
            $domainDirectory,
        );

        $finalPath =
            $this->privateKeyPath(
                $domain->value,
            );

        if (
            is_link(
                $finalPath,
            )
        ) {
            throw new RuntimeException(
                'DKIM private key path cannot be a symbolic link.',
            );
        }

        if (
            file_exists(
                $finalPath,
            )
        ) {
            return $this->loadExisting(
                $finalPath,
            );
        }

        $privateKey =
            openssl_pkey_new([
                'private_key_bits'
                    => 2048,
                'private_key_type'
                    => OPENSSL_KEYTYPE_RSA,
            ]);

        if ($privateKey === false) {
            throw new RuntimeException(
                'Unable to generate DKIM private key.',
            );
        }

        $privatePem = '';

        if (
            !openssl_pkey_export(
                $privateKey,
                $privatePem,
            )
            || $privatePem === ''
        ) {
            throw new RuntimeException(
                'Unable to export DKIM private key.',
            );
        }

        $temporaryPath =
            sprintf(
                '%s/.%s.key.tmp.%s',
                $domainDirectory,
                $this->selector,
                bin2hex(
                    random_bytes(8),
                ),
            );

        $previousUmask =
            umask(
                0027,
            );

        try {
            $written =
                file_put_contents(
                    $temporaryPath,
                    $privatePem,
                    LOCK_EX,
                );

            if (
                !is_string(
                    $privatePem,
                )
                || $written === false
                || $written
                    !== strlen(
                        $privatePem,
                    )
            ) {
                throw new RuntimeException(
                    'Unable to persist temporary DKIM private key.',
                );
            }

            if (
                !chmod(
                    $temporaryPath,
                    0440,
                )
            ) {
                throw new RuntimeException(
                    'Unable to protect temporary DKIM private key.',
                );
            }

            /*
             * The Messenger handler serializes provisioning for a domain
             * through a PostgreSQL advisory lock.
             *
             * rename() publishes a complete key atomically.
             */
            if (
                !rename(
                    $temporaryPath,
                    $finalPath,
                )
            ) {
                throw new RuntimeException(
                    'Unable to publish DKIM private key.',
                );
            }
        } finally {
            umask(
                $previousUmask,
            );

            if (
                file_exists(
                    $temporaryPath,
                )
                || is_link(
                    $temporaryPath,
                )
            ) {
                @unlink(
                    $temporaryPath,
                );
            }
        }

        return $this->loadExisting(
            $finalPath,
        );
    }

    public function privateKeyPath(
        string $rawDomain,
    ): string {
        $domain =
            new DomainName(
                $rawDomain,
            );

        return sprintf(
            '%s/%s.key',
            $this->domainDirectory(
                $domain->value,
            ),
            $this->selector,
        );
    }

    private function domainDirectory(
        string $domain,
    ): string {
        return sprintf(
            '%s/%s',
            rtrim(
                $this->privateDirectory,
                '/',
            ),
            $domain,
        );
    }

    private function ensureDomainDirectory(
        string $path,
    ): void {
        if (
            is_link(
                $path,
            )
        ) {
            throw new RuntimeException(
                'DKIM domain directory cannot be a symbolic link.',
            );
        }

        if (
            file_exists(
                $path,
            )
        ) {
            if (
                !is_dir(
                    $path,
                )
            ) {
                throw new RuntimeException(
                    'Invalid DKIM domain-directory filesystem object.',
                );
            }
        } else {
            $previousUmask =
                umask(
                    0027,
                );

            try {
                if (
                    !mkdir(
                        $path,
                        0750,
                    )
                ) {
                    throw new RuntimeException(
                        'Unable to create DKIM domain directory.',
                    );
                }
            } finally {
                umask(
                    $previousUmask,
                );
            }
        }

        if (
            !chmod(
                $path,
                0750,
            )
        ) {
            throw new RuntimeException(
                'Unable to protect DKIM domain directory.',
            );
        }

        $mode =
            fileperms(
                $path,
            );

        if (
            !is_int(
                $mode,
            )
            || (
                $mode
                & 0777
            ) !== 0750
        ) {
            throw new RuntimeException(
                'DKIM domain directory has unsafe permissions.',
            );
        }
    }

    private function loadExisting(
        string $path,
    ): DkimKeyMaterial {
        if (
            is_link(
                $path,
            )
            || !is_file(
                $path,
            )
        ) {
            throw new RuntimeException(
                'Invalid DKIM private-key filesystem object.',
            );
        }

        $mode =
            fileperms(
                $path,
            );

        if (
            !is_int(
                $mode,
            )
            || (
                $mode
                & 0777
            ) !== 0440
        ) {
            throw new RuntimeException(
                'DKIM private key has unsafe permissions.',
            );
        }

        $privatePem =
            file_get_contents(
                $path,
            );

        if (
            $privatePem === false
            || $privatePem === ''
        ) {
            throw new RuntimeException(
                'Unable to read DKIM private key.',
            );
        }

        $privateKey =
            openssl_pkey_get_private(
                $privatePem,
            );

        if ($privateKey === false) {
            throw new RuntimeException(
                'Stored DKIM private key is invalid.',
            );
        }

        $details =
            openssl_pkey_get_details(
                $privateKey,
            );

        if (
            $details === false
            || $details['type']
                !== OPENSSL_KEYTYPE_RSA
            || $details['bits']
                !== 2048
            || !isset(
                $details['key'],
            )
            || !is_string(
                $details['key'],
            )
        ) {
            throw new RuntimeException(
                'Stored DKIM private key is not RSA-2048.',
            );
        }

        return new DkimKeyMaterial(
            $this->selector,
            self::publicKeyFromPem(
                $details['key'],
            ),
        );
    }

    private static function publicKeyFromPem(
        string $publicPem,
    ): string {
        $publicKey =
            preg_replace(
                [
                    '/-----BEGIN PUBLIC KEY-----/',
                    '/-----END PUBLIC KEY-----/',
                    '/\s+/',
                ],
                '',
                $publicPem,
            );

        if (
            !is_string(
                $publicKey,
            )
            || $publicKey === ''
            || base64_decode(
                $publicKey,
                true,
            ) === false
        ) {
            throw new RuntimeException(
                'Unable to derive DKIM public key.',
            );
        }

        return $publicKey;
    }
}
