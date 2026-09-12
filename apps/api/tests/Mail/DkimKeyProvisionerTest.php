<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\DkimKeyProvisioner;
use OpenSSLAsymmetricKey;
use PHPUnit\Framework\TestCase;

final class DkimKeyProvisionerTest extends TestCase
{
    private string $directory;

    protected function setUp(): void
    {
        $this->directory =
            sprintf(
                '%s/heymail-dkim-%s',
                sys_get_temp_dir(),
                bin2hex(
                    random_bytes(8),
                ),
            );

        self::assertTrue(
            mkdir(
                $this->directory,
                0700,
            ),
        );
    }

    protected function tearDown(): void
    {
        if (
            !isset(
                $this->directory,
            )
            || !is_dir(
                $this->directory,
            )
        ) {
            return;
        }

        $iterator =
            new \RecursiveIteratorIterator(
                new \RecursiveDirectoryIterator(
                    $this->directory,
                    \FilesystemIterator::SKIP_DOTS,
                ),
                \RecursiveIteratorIterator::CHILD_FIRST,
            );

        foreach ($iterator as $entry) {
            if (!$entry instanceof \SplFileInfo) {
                continue;
            }

            if ($entry->isDir()) {
                rmdir(
                    $entry->getPathname(),
                );
            } else {
                unlink(
                    $entry->getPathname(),
                );
            }
        }

        rmdir(
            $this->directory,
        );
    }

    public function testProvisionCreatesReusableRsa2048Key(): void
    {
        $provisioner =
            new DkimKeyProvisioner(
                $this->directory,
                'hm1',
            );

        $first =
            $provisioner->provision(
                'Example.COM',
            );

        $path =
            $provisioner->privateKeyPath(
                'example.com',
            );

        self::assertSame(
            $this->directory
                . '/example.com/hm1.key',
            $path,
        );

        self::assertFileExists(
            $path,
        );

        self::assertSame(
            0750,
            fileperms(
                dirname(
                    $path,
                ),
            )
                & 0777,
        );

        self::assertSame(
            0440,
            fileperms(
                $path,
            )
                & 0777,
        );

        $privatePem =
            file_get_contents(
                $path,
            );

        self::assertIsString(
            $privatePem,
        );

        $key =
            openssl_pkey_get_private(
                $privatePem,
            );

        self::assertInstanceOf(
            OpenSSLAsymmetricKey::class,
            $key,
        );

        $details =
            openssl_pkey_get_details(
                $key,
            );

        self::assertIsArray(
            $details,
        );

        self::assertSame(
            OPENSSL_KEYTYPE_RSA,
            $details['type'],
        );

        self::assertSame(
            2048,
            $details['bits'],
        );

        self::assertSame(
            'hm1',
            $first->selector,
        );

        self::assertNotSame(
            '',
            $first->publicKey,
        );

        $second =
            $provisioner->provision(
                'example.com',
            );

        self::assertSame(
            $first->publicKey,
            $second->publicKey,
        );
    }

    public function testLongDnsDomainUsesSeparateDirectoryComponent(): void
    {
        $label =
            str_repeat(
                'a',
                63,
            );

        $domain =
            implode(
                '.',
                [
                    $label,
                    $label,
                    $label,
                    str_repeat(
                        'b',
                        61,
                    ),
                ],
            );

        $provisioner =
            new DkimKeyProvisioner(
                $this->directory,
                'hm1',
            );

        $material =
            $provisioner->provision(
                $domain,
            );

        self::assertSame(
            'hm1',
            $material->selector,
        );

        self::assertFileExists(
            sprintf(
                '%s/%s/hm1.key',
                $this->directory,
                $domain,
            ),
        );
    }
}
