<?php

declare(strict_types=1);

namespace HeyMail;

use InvalidArgumentException;

final class MessageBuilder
{
    private ?string $from = null;

    /** @var list<array{email: string, name?: string}> */
    private array $to = [];

    private ?string $subject = null;
    private ?string $text = null;
    private ?string $html = null;
    private ?string $replyTo = null;
    private ?string $idempotencyKey = null;

    public function __construct(
        private readonly HeyMailHub $hub,
    ) {
    }

    public function from(string $email): self
    {
        $this->from = self::email(
            $email,
        );

        return $this;
    }

    public function to(
        string $email,
        ?string $name = null,
    ): self {
        $recipient = [
            'email' => self::email($email),
        ];

        if (
            $name !== null
            && trim($name) !== ''
        ) {
            $recipient['name'] = trim($name);
        }

        $this->to[] = $recipient;

        return $this;
    }

    public function subject(string $subject): self
    {
        $subject = trim($subject);

        if ($subject === '') {
            throw new InvalidArgumentException(
                'HeyMail subject cannot be empty.',
            );
        }

        $this->subject = $subject;

        return $this;
    }

    public function text(string $text): self
    {
        $this->text = $text;

        return $this;
    }

    public function html(string $html): self
    {
        $this->html = $html;

        return $this;
    }

    public function replyTo(string $email): self
    {
        $this->replyTo = self::email(
            $email,
        );

        return $this;
    }

    public function idempotencyKey(
        string $key,
    ): self {
        $this->idempotencyKey = $key;

        return $this;
    }

    /**
     * @return array<string, mixed>
     */
    public function send(): array
    {
        if ($this->from === null) {
            throw new InvalidArgumentException(
                'HeyMail From address is required.',
            );
        }

        if ($this->to === []) {
            throw new InvalidArgumentException(
                'HeyMail needs at least one recipient.',
            );
        }

        if ($this->subject === null) {
            throw new InvalidArgumentException(
                'HeyMail subject is required.',
            );
        }

        if (
            $this->text === null
            && $this->html === null
        ) {
            throw new InvalidArgumentException(
                'HeyMail needs a text or HTML body.',
            );
        }

        $payload = [
            'from' => [
                'email' => $this->from,
            ],
            'to' => $this->to,
            'subject' => $this->subject,
        ];

        if ($this->text !== null) {
            $payload['text'] = $this->text;
        }

        if ($this->html !== null) {
            $payload['html'] = $this->html;
        }

        if ($this->replyTo !== null) {
            $payload['replyTo'] = [
                'email' => $this->replyTo,
            ];
        }

        return $this->hub->submit(
            $payload,
            $this->idempotencyKey,
        );
    }

    private static function email(
        string $email,
    ): string {
        $email = trim($email);

        if (
            filter_var(
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
}
