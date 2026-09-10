<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;

final readonly class OutboundEmailPayload
{
    private const int MAX_RECIPIENTS = 50;
    private const int MAX_SUBJECT_BYTES = 255;
    private const int MAX_TEXT_BYTES = 1048576;
    private const int MAX_HTML_BYTES = 2097152;

    /**
     * @param list<EmailAddress> $to
     */
    public function __construct(
        public EmailAddress $from,
        public array $to,
        public string $subject,
        public ?string $textPart = null,
        public ?string $htmlPart = null,
        public ?EmailAddress $replyTo = null,
    ) {
        self::assertRecipients($this->to);
        self::assertSubject($this->subject);

        self::assertBodyPart(
            $this->textPart,
            self::MAX_TEXT_BYTES,
            'text',
        );

        self::assertBodyPart(
            $this->htmlPart,
            self::MAX_HTML_BYTES,
            'HTML',
        );

        if (
            ($this->textPart === null || $this->textPart === '')
            && ($this->htmlPart === null || $this->htmlPart === '')
        ) {
            throw new InvalidArgumentException(
                'Outbound email requires text or HTML content.',
            );
        }
    }

    /**
     * @param array<mixed, mixed> $data
     */
    public static function fromArray(array $data): self
    {
        $allowedKeys = [
            'from',
            'to',
            'subject',
            'text',
            'html',
            'replyTo',
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
                    'Unexpected outbound email field.',
                );
            }
        }

        $fromData = $data['from'] ?? null;

        if (!is_array($fromData)) {
            throw new InvalidArgumentException(
                'Outbound email from field is required.',
            );
        }

        $toData = $data['to'] ?? null;

        if (
            !is_array($toData)
            || !array_is_list($toData)
        ) {
            throw new InvalidArgumentException(
                'Outbound email to field must be a list.',
            );
        }

        $to = [];

        foreach ($toData as $recipientData) {
            if (!is_array($recipientData)) {
                throw new InvalidArgumentException(
                    'Outbound recipient must be an object.',
                );
            }

            $to[] = EmailAddress::fromArray(
                $recipientData,
            );
        }

        $subject = $data['subject'] ?? null;

        if (!is_string($subject)) {
            throw new InvalidArgumentException(
                'Outbound email subject is required.',
            );
        }

        $textPart = $data['text'] ?? null;

        if (
            $textPart !== null
            && !is_string($textPart)
        ) {
            throw new InvalidArgumentException(
                'Outbound email text part must be a string or null.',
            );
        }

        $htmlPart = $data['html'] ?? null;

        if (
            $htmlPart !== null
            && !is_string($htmlPart)
        ) {
            throw new InvalidArgumentException(
                'Outbound email HTML part must be a string or null.',
            );
        }

        $replyToData = $data['replyTo'] ?? null;
        $replyTo = null;

        if ($replyToData !== null) {
            if (!is_array($replyToData)) {
                throw new InvalidArgumentException(
                    'Outbound email replyTo must be an object or null.',
                );
            }

            $replyTo = EmailAddress::fromArray(
                $replyToData,
            );
        }

        return new self(
            from: EmailAddress::fromArray(
                $fromData,
            ),
            to: $to,
            subject: $subject,
            textPart: $textPart,
            htmlPart: $htmlPart,
            replyTo: $replyTo,
        );
    }

    /**
     * @return array{
     *     from: array{email: string, name?: string},
     *     to: list<array{email: string, name?: string}>,
     *     subject: string,
     *     text: ?string,
     *     html: ?string,
     *     replyTo: array{email: string, name?: string}|null
     * }
     */
    public function toArray(): array
    {
        return [
            'from' => $this->from->toArray(),
            'to' => array_map(
                static fn (
                    EmailAddress $address,
                ): array => $address->toArray(),
                $this->to,
            ),
            'subject' => $this->subject,
            'text' => $this->textPart,
            'html' => $this->htmlPart,
            'replyTo' => $this->replyTo?->toArray(),
        ];
    }

    /**
     * @param list<EmailAddress> $recipients
     */
    private static function assertRecipients(
        array $recipients,
    ): void {
        $count = count($recipients);

        if (
            $count === 0
            || $count > self::MAX_RECIPIENTS
        ) {
            throw new InvalidArgumentException(
                'Outbound email must contain between 1 and 50 recipients.',
            );
        }

        $seen = [];

        foreach ($recipients as $recipient) {
            $normalized = strtolower(
                $recipient->email,
            );

            if (isset($seen[$normalized])) {
                throw new InvalidArgumentException(
                    'Outbound email contains duplicate recipients.',
                );
            }

            $seen[$normalized] = true;
        }
    }

    private static function assertSubject(
        string $subject,
    ): void {
        if (
            trim($subject) === ''
            || strlen($subject) > self::MAX_SUBJECT_BYTES
            || preg_match(
                '/[\x00-\x1F\x7F]/',
                $subject,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Invalid outbound email subject.',
            );
        }
    }

    private static function assertBodyPart(
        ?string $body,
        int $maxBytes,
        string $label,
    ): void {
        if ($body === null) {
            return;
        }

        if (
            strlen($body) > $maxBytes
            || str_contains(
                $body,
                "\0",
            )
        ) {
            throw new InvalidArgumentException(
                sprintf(
                    'Invalid outbound email %s part.',
                    $label,
                ),
            );
        }
    }
}
