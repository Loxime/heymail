<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\DkimKeyMaterial;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class DkimKeyMaterialTest extends TestCase
{
    public function testMaterialExposesDnsRecord(): void
    {
        $publicKey =
            base64_encode(
                'public-key',
            );

        $material =
            new DkimKeyMaterial(
                'hm1',
                $publicKey,
            );

        self::assertSame(
            'hm1._domainkey.example.com',
            $material->recordName(
                'example.com',
            ),
        );

        self::assertSame(
            sprintf(
                'v=DKIM1; k=rsa; p=%s',
                $publicKey,
            ),
            $material->recordValue(),
        );
    }

    public function testInvalidSelectorIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new DkimKeyMaterial(
            'bad selector',
            base64_encode(
                'key',
            ),
        );
    }
}
