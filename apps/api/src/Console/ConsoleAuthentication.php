<?php

declare(strict_types=1);

namespace App\Console;

use DateTimeImmutable;
use DateTimeZone;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use Symfony\Component\HttpFoundation\Cookie;
use Symfony\Component\HttpFoundation\Request;

final readonly class ConsoleAuthentication
{
    public const string COOKIE_NAME = 'heymail_session';

    private const int SESSION_DAYS = 30;

    public function __construct(
        private Connection $connection,
    ) {
    }

    /**
     * @return array{
     *     token: string,
     *     expiresAt: DateTimeImmutable,
     *     user: array{
     *         id: int,
     *         email: string,
     *         firstName: string,
     *         lastName: string
     *     }
     * }
     */
    public function login(
        string $email,
        string $password,
    ): array {
        $email = self::normalizeEmail(
            $email,
        );

        if (
            $password === ''
            || strlen($password) > 4096
        ) {
            throw new InvalidArgumentException(
                'Invalid console credentials.',
            );
        }

        $row =
            $this->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT
    id,
    email,
    first_name,
    last_name,
    password_hash
FROM console_user
WHERE email = :email
SQL,
                    [
                        'email' => $email,
                    ],
                );

        if (
            !is_array($row)
            || !isset($row['password_hash'])
            || !is_string($row['password_hash'])
            || !password_verify(
                $password,
                $row['password_hash'],
            )
        ) {
            throw new InvalidArgumentException(
                'Invalid console credentials.',
            );
        }

        $now = self::now();

        $this->connection
            ->executeStatement(
                'DELETE FROM console_session WHERE expires_at <= :now',
                [
                    'now' => $now->format('Y-m-d H:i:s'),
                ],
            );

        $token = bin2hex(
            random_bytes(32),
        );

        $expiresAt = $now->modify(
            sprintf(
                '+%d days',
                self::SESSION_DAYS,
            ),
        );

        $user = self::serializeUser(
            $row,
        );

        $this->connection
            ->insert(
                'console_session',
                [
                    'token_hash' => hash(
                        'sha256',
                        $token,
                    ),
                    'user_id' => $user['id'],
                    'created_at' => $now->format('Y-m-d H:i:s'),
                    'last_seen_at' => $now->format('Y-m-d H:i:s'),
                    'expires_at' => $expiresAt->format('Y-m-d H:i:s'),
                ],
            );

        return [
            'token' => $token,
            'expiresAt' => $expiresAt,
            'user' => $user,
        ];
    }

    /**
     * @return array{
     *     id: int,
     *     email: string,
     *     firstName: string,
     *     lastName: string
     * }|null
     */
    public function authenticate(
        Request $request,
    ): ?array {
        $token = $request
            ->cookies
            ->get(
                self::COOKIE_NAME,
            );

        if (
            !is_string($token)
            || preg_match(
                '/^[a-f0-9]{64}$/D',
                $token,
            ) !== 1
        ) {
            return null;
        }

        $row =
            $this->connection
                ->fetchAssociative(
                    <<<'SQL'
SELECT
    u.id,
    u.email,
    u.first_name,
    u.last_name
FROM console_session s
INNER JOIN console_user u
    ON u.id = s.user_id
WHERE s.token_hash = :token_hash
  AND s.expires_at > :now
SQL,
                    [
                        'token_hash' => hash(
                            'sha256',
                            $token,
                        ),
                        'now' => self::now()
                            ->format('Y-m-d H:i:s'),
                    ],
                );

        if (!is_array($row)) {
            return null;
        }

        return self::serializeUser(
            $row,
        );
    }

    public function logout(
        Request $request,
    ): void {
        $token = $request
            ->cookies
            ->get(
                self::COOKIE_NAME,
            );

        if (!is_string($token)) {
            return;
        }

        $this->connection
            ->executeStatement(
                'DELETE FROM console_session WHERE token_hash = :token_hash',
                [
                    'token_hash' => hash(
                        'sha256',
                        $token,
                    ),
                ],
            );
    }

    public static function sessionCookie(
        string $token,
        DateTimeImmutable $expiresAt,
        bool $secure,
    ): Cookie {
        return Cookie::create(
            self::COOKIE_NAME,
        )
            ->withValue($token)
            ->withExpires($expiresAt)
            ->withPath('/')
            ->withSecure($secure)
            ->withHttpOnly(true)
            ->withSameSite(
                Cookie::SAMESITE_STRICT,
            );
    }

    public static function expiredCookie(
        bool $secure,
    ): Cookie {
        return Cookie::create(
            self::COOKIE_NAME,
        )
            ->withValue('')
            ->withExpires(
                new DateTimeImmutable(
                    '@1',
                ),
            )
            ->withPath('/')
            ->withSecure($secure)
            ->withHttpOnly(true)
            ->withSameSite(
                Cookie::SAMESITE_STRICT,
            );
    }

    public static function normalizeEmail(
        string $email,
    ): string {
        $email = strtolower(
            trim($email),
        );

        if (
            strlen($email) > 254
            || filter_var(
                $email,
                FILTER_VALIDATE_EMAIL,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Invalid email address.',
            );
        }

        return $email;
    }

    /**
     * @param array<string, mixed> $row
     *
     * @return array{
     *     id: int,
     *     email: string,
     *     firstName: string,
     *     lastName: string
     * }
     */
    private static function serializeUser(
        array $row,
    ): array {
        $id = filter_var(
            $row['id'] ?? null,
            FILTER_VALIDATE_INT,
            [
                'options' => [
                    'min_range' => 1,
                ],
            ],
        );

        $email = $row['email'] ?? null;
        $firstName = $row['first_name'] ?? null;
        $lastName = $row['last_name'] ?? null;

        if (
            !is_int($id)
            || !is_string($email)
            || !is_string($firstName)
            || !is_string($lastName)
        ) {
            throw new InvalidArgumentException(
                'Invalid console user row.',
            );
        }

        return [
            'id' => $id,
            'email' => $email,
            'firstName' => $firstName,
            'lastName' => $lastName,
        ];
    }

    private static function now(): DateTimeImmutable
    {
        return new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        );
    }
}
