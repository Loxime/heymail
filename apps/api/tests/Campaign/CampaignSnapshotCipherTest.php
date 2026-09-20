<?php
declare(strict_types=1);

namespace App\Tests\Campaign;

use App\Campaign\CampaignSnapshotCipher;
use PHPUnit\Framework\TestCase;
use RuntimeException;

final class CampaignSnapshotCipherTest extends TestCase
{
    private string $keyFile;

    protected function setUp(): void
    {
        $path = tempnam(sys_get_temp_dir(), 'hm-campaign-');
        self::assertIsString($path);
        $this->keyFile = $path;
        file_put_contents(
            $path,
            sodium_bin2base64(
                random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
                SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
            ),
        );
    }

    protected function tearDown(): void
    {
        @unlink($this->keyFile);
    }

    public function testRoundTrip(): void
    {
        $cipher = new CampaignSnapshotCipher($this->keyFile);
        $snapshot = ['recipients' => [['email' => 'ada@example.test']]];
        $encrypted = $cipher->encrypt(7, 11, $snapshot);

        self::assertSame($snapshot, $cipher->decrypt(7, 11, $encrypted));
    }

    public function testCrossWorkspaceTransplantFails(): void
    {
        $cipher = new CampaignSnapshotCipher($this->keyFile);
        $encrypted = $cipher->encrypt(7, 11, ['secret' => 'x']);

        $this->expectException(RuntimeException::class);
        $cipher->decrypt(8, 11, $encrypted);
    }

    public function testCrossCampaignTransplantFails(): void
    {
        $cipher = new CampaignSnapshotCipher($this->keyFile);
        $encrypted = $cipher->encrypt(7, 11, ['secret' => 'x']);

        $this->expectException(RuntimeException::class);
        $cipher->decrypt(7, 12, $encrypted);
    }
}
