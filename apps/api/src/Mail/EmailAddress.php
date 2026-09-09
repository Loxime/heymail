<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;

final readonly class EmailAddress
{
    private const int MAX_EMAIL_BYTES = 254;
    private const int MAX_NAME_BYTES = 128;

    public function __construct(
        public string $email,
        public ?string $name = null,
    ) {
        self::assertEmail($this->email);
        self::assertName($this->name);
    }

    /**
     * @param array<mixed, mixed> $data
     */
    public static function fromArray(array $data): self
    {
        $allowedKeys = [
            'email',
            'name',
        ];

        foreach (array_keys($data) as $key) {
            if (
                !is_string($key)
                || !in_array(
                    $key,
                    $allowedKeys,
                    true,
                )
            ) {
                throw new InvalidArgumentException(
                    'Unexpected email address field.',
                );
            }
        }

        $email = $data['email'] ?? null;

        if (!is_string($email)) {
            throw new InvalidArgumentException(
                'Email address must contain an email string.',
            );
        }

        $name = $data['name'] ?? null;

        if (
            $name !== null
            && !is_string($name)
        ) {
            throw new InvalidArgumentException(
                'Email address name must be a string or null.',
            );
        }

        return new self(
            email: $email,
            name: $name,
        );
    }

    /**
     * @return array{email: string, name?: string}
     */
    public function toArray(): array
    {
        $data = [
            'email' => $this->email,
        ];

        if ($this->name !== null) {
            $data['name'] = $this->name;
        }

        return $data;
    }

    private static function assertEmail(string $email): void
    {
        if (
            $email === ''
            || strlen($email) > self::MAX_EMAIL_BYTES
            || trim($email) !== $email
            || preg_match(
                '/[\x00-\x20\x7F]/',
                $email,
            ) === 1
            || filter_var(
                $email,
                FILTER_VALIDATE_EMAIL,
            ) === false
        ) {
            throw new InvalidArgumentException(
                'Invalid email address.',
            );
        }
    }

    private static function assertName(?string $name): void
    {
        if ($name === null) {
            return;
        }

        if (
            trim($name) === ''
            || strlen($name) > self::MAX_NAME_BYTES
            || preg_match(
                '/[\x00-\x1F\x7F]/',
                $name,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Invalid email address display name.',
            );
        }
    }
}
