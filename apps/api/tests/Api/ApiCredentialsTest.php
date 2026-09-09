<?php

declare(strict_types=1);

namespace App\Tests\Api;

use App\Api\ApiCredentials;
use PHPUnit\Framework\TestCase;
use Symfony\Component\HttpFoundation\Request;

final class ApiCredentialsTest extends TestCase
{
    private string $keyFile;
    private string $secretFile;

    protected function setUp(): void
    {
        $keyFile = tempnam(
            sys_get_temp_dir(),
            'heymail-api-key-',
        );

        $secretFile = tempnam(
            sys_get_temp_dir(),
            'heymail-api-secret-',
        );

        self::assertIsString($keyFile);
        self::assertIsString($secretFile);

        $this->keyFile = $keyFile;
        $this->secretFile = $secretFile;

        file_put_contents(
            $this->keyFile,
            'hm_' . str_repeat('a', 32),
        );

        file_put_contents(
            $this->secretFile,
            str_repeat('b', 64),
        );
    }

    protected function tearDown(): void
    {
        @unlink($this->keyFile);
        @unlink($this->secretFile);
    }

    public function testValidCredentialsAreAccepted(): void
    {
        $request = Request::create(
            '/api/v1/send',
        );

        $request->headers->set(
            'Authorization',
            'Basic ' . base64_encode(
                'hm_'
                . str_repeat('a', 32)
                . ':'
                . str_repeat('b', 64),
            ),
        );

        self::assertTrue(
            $this
                ->credentials()
                ->authorizes($request),
        );
    }

    public function testWrongSecretIsRejected(): void
    {
        $request = Request::create(
            '/api/v1/send',
        );

        $request->headers->set(
            'Authorization',
            'Basic ' . base64_encode(
                'hm_'
                . str_repeat('a', 32)
                . ':wrong',
            ),
        );

        self::assertFalse(
            $this
                ->credentials()
                ->authorizes($request),
        );
    }

    public function testMalformedAuthorizationIsRejected(): void
    {
        $request = Request::create(
            '/api/v1/send',
        );

        $request->headers->set(
            'Authorization',
            'Basic !!!',
        );

        self::assertFalse(
            $this
                ->credentials()
                ->authorizes($request),
        );
    }

    private function credentials(): ApiCredentials
    {
        return new ApiCredentials(
            $this->keyFile,
            $this->secretFile,
        );
    }
}
