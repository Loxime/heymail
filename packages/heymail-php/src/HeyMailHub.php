<?php

declare(strict_types=1);

namespace HeyMail;

use HeyMail\Exception\ApiException;
use HeyMail\Exception\TransportException;
use JsonException;
use RuntimeException;

final readonly class HeyMailHub
{
    public function __construct(
        private string $baseUri,
        private string $apiKey,
        private string $apiSecret,
        private ?string $defaultFrom = null,
        private int $connectTimeoutSeconds = 3,
        private int $timeoutSeconds = 15,
        private ?string $caFile = null,
        private ?string $captureDsn = null,
    ) {
        if ($this->captureDsn !== null) {
            $this->captureEndpoint();

            return;
        }

        if (!str_starts_with($this->baseUri, 'https://')) {
            throw new RuntimeException(
                'HeyMail base URI must use HTTPS.',
            );
        }

        if (
            $this->caFile !== null
            && !is_readable(
                $this->caFile,
            )
        ) {
            throw new RuntimeException(
                'HeyMail CA file is not readable.',
            );
        }
    }

    public static function fromEnvironment(): self
    {
        $mode = strtolower(
            self::environment(
                'HEYMAIL_MODE',
                'api',
            ),
        );

        $defaultFrom = self::optionalEnvironment(
            'HEYMAIL_DEFAULT_FROM',
        );

        if ($mode === 'capture') {
            return new self(
                baseUri: 'https://capture.invalid',
                apiKey: '',
                apiSecret: '',
                defaultFrom: $defaultFrom,
                captureDsn: self::environment(
                    'HEYMAIL_CAPTURE_DSN',
                    'smtp://127.0.0.1:1025',
                ),
            );
        }

        if ($mode !== 'api') {
            throw new RuntimeException(
                'HEYMAIL_MODE must be "api" or "capture".',
            );
        }

        return new self(
            baseUri: self::environment(
                'HEYMAIL_BASE_URI',
            ),
            apiKey: self::secretEnvironment(
                'HEYMAIL_API_KEY',
                'HEYMAIL_API_KEY_FILE',
            ),
            apiSecret: self::secretEnvironment(
                'HEYMAIL_API_SECRET',
                'HEYMAIL_API_SECRET_FILE',
            ),
            defaultFrom: $defaultFrom,
            caFile: self::optionalEnvironment(
                'HEYMAIL_CA_FILE',
            ),
        );
    }

    public function message(): MessageBuilder
    {
        $message = new MessageBuilder(
            $this,
        );

        if ($this->defaultFrom !== null) {
            $message->from(
                $this->defaultFrom,
            );
        }

        return $message;
    }

    /**
     * @return array<string, mixed>
     */
    public function alert(
        string $to,
        string $subject,
        string $message,
        ?string $from = null,
    ): array {
        $builder = $this
            ->message()
            ->to($to)
            ->subject($subject)
            ->text($message);

        if ($from !== null) {
            $builder->from($from);
        }

        return $builder->send();
    }

    /**
     * @param array<string, mixed> $payload
     *
     * @return array<string, mixed>
     */
    public function submit(
        array $payload,
        ?string $idempotencyKey = null,
    ): array {
        if ($this->captureDsn !== null) {
            return $this->submitToCapture(
                $payload,
            );
        }

        $idempotencyKey ??= sprintf(
            'php-%s',
            bin2hex(random_bytes(16)),
        );

        try {
            $body = json_encode(
                $payload,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException $exception) {
            throw new RuntimeException(
                'Unable to encode HeyMail payload.',
                0,
                $exception,
            );
        }

        $handle = curl_init(
            rtrim($this->baseUri, '/')
            . '/api/v1/send',
        );

        if ($handle === false) {
            throw new TransportException(
                'Unable to initialize HeyMail transport.',
            );
        }

        $options = [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $body,
            CURLOPT_USERPWD => sprintf(
                '%s:%s',
                $this->apiKey,
                $this->apiSecret,
            ),
            CURLOPT_HTTPAUTH => CURLAUTH_BASIC,
            CURLOPT_HTTPHEADER => [
                'Accept: application/json',
                'Content-Type: application/json',
                'Idempotency-Key: '
                    . $idempotencyKey,
            ],
            CURLOPT_CONNECTTIMEOUT =>
                $this->connectTimeoutSeconds,
            CURLOPT_TIMEOUT =>
                $this->timeoutSeconds,
        ];

        if ($this->caFile !== null) {
            $options[CURLOPT_CAINFO] =
                $this->caFile;
        }

        curl_setopt_array(
            $handle,
            $options,
        );

        $responseBody = curl_exec(
            $handle,
        );

        if (!is_string($responseBody)) {
            $error = curl_error($handle);
            curl_close($handle);

            throw new TransportException(
                'HeyMail submission outcome is unknown after transport failure: '
                . $error,
            );
        }

        $status = (int) curl_getinfo(
            $handle,
            CURLINFO_RESPONSE_CODE,
        );

        curl_close($handle);

        try {
            $decoded = json_decode(
                $responseBody,
                true,
                32,
                JSON_THROW_ON_ERROR,
            );
        } catch (JsonException $exception) {
            throw new TransportException(
                sprintf(
                    'HeyMail returned invalid JSON (HTTP %d).',
                    $status,
                ),
                0,
                $exception,
            );
        }

        if (!is_array($decoded)) {
            throw new TransportException(
                'HeyMail returned an invalid response document.',
            );
        }

        if (
            $status !== 200
            && $status !== 202
        ) {
            $error = $decoded['error'] ?? null;

            throw new ApiException(
                $status,
                is_array($error)
                    && isset($error['code'])
                    && is_string($error['code'])
                        ? $error['code']
                        : null,
                is_array($error)
                    && isset($error['message'])
                    && is_string($error['message'])
                        ? $error['message']
                        : sprintf(
                            'HeyMail returned HTTP %d.',
                            $status,
                        ),
            );
        }

        return $decoded;
    }

    /**
     * @param array<string, mixed> $payload
     *
     * @return array<string, mixed>
     */
    private function submitToCapture(
        array $payload,
    ): array {
        [$host, $port] = $this->captureEndpoint();

        $from = self::payloadEmail(
            $payload,
            'from',
        );

        $recipientRows = $payload['to'] ?? null;

        if (
            !is_array($recipientRows)
            || $recipientRows === []
        ) {
            throw new RuntimeException(
                'HeyMail capture needs at least one recipient.',
            );
        }

        $recipients = [];
        $recipientHeaders = [];

        foreach ($recipientRows as $recipient) {
            if (!is_array($recipient)) {
                throw new RuntimeException(
                    'HeyMail capture recipient is invalid.',
                );
            }

            $email = self::arrayEmail(
                $recipient,
            );

            $recipients[] = $email;

            $name = $recipient['name'] ?? null;

            if (
                is_string($name)
                && trim($name) !== ''
            ) {
                self::rejectHeaderInjection(
                    $name,
                );

                $recipientHeaders[] = sprintf(
                    '%s <%s>',
                    self::encodedHeader(
                        trim($name),
                    ),
                    $email,
                );
            } else {
                $recipientHeaders[] = sprintf(
                    '<%s>',
                    $email,
                );
            }
        }

        $subject = $payload['subject'] ?? null;

        if (
            !is_string($subject)
            || trim($subject) === ''
        ) {
            throw new RuntimeException(
                'HeyMail capture subject is required.',
            );
        }

        self::rejectHeaderInjection(
            $subject,
        );

        $textBody = $payload['text'] ?? null;
        $htmlBody = $payload['html'] ?? null;

        if (
            $textBody !== null
            && !is_string($textBody)
        ) {
            throw new RuntimeException(
                'HeyMail capture text body is invalid.',
            );
        }

        if (
            $htmlBody !== null
            && !is_string($htmlBody)
        ) {
            throw new RuntimeException(
                'HeyMail capture HTML body is invalid.',
            );
        }

        if (
            $textBody === null
            && $htmlBody === null
        ) {
            throw new RuntimeException(
                'HeyMail capture needs a text or HTML body.',
            );
        }

        $messageId = sprintf(
            '<%s@heymail.capture>',
            bin2hex(
                random_bytes(16),
            ),
        );

        $headers = [
            sprintf(
                'From: <%s>',
                $from,
            ),
            sprintf(
                'To: %s',
                implode(
                    ', ',
                    $recipientHeaders,
                ),
            ),
            sprintf(
                'Subject: %s',
                self::encodedHeader(
                    trim($subject),
                ),
            ),
            'Date: '
                . gmdate(
                    'D, d M Y H:i:s',
                )
                . ' +0000',
            'Message-ID: '
                . $messageId,
            'MIME-Version: 1.0',
        ];

        $replyTo = $payload['replyTo'] ?? null;

        if ($replyTo !== null) {
            if (!is_array($replyTo)) {
                throw new RuntimeException(
                    'HeyMail capture Reply-To is invalid.',
                );
            }

            $headers[] = sprintf(
                'Reply-To: <%s>',
                self::arrayEmail(
                    $replyTo,
                ),
            );
        }

        $body = '';

        if (
            $textBody !== null
            && $htmlBody !== null
        ) {
            $boundary =
                '=_HeyMail_'
                . bin2hex(
                    random_bytes(12),
                );

            $headers[] =
                'Content-Type: multipart/alternative; boundary="'
                . $boundary
                . '"';

            $body = implode(
                "\r\n",
                [
                    '--' . $boundary,
                    'Content-Type: text/plain; charset=UTF-8',
                    'Content-Transfer-Encoding: quoted-printable',
                    '',
                    quoted_printable_encode(
                        self::normalizeBody(
                            $textBody,
                        ),
                    ),
                    '--' . $boundary,
                    'Content-Type: text/html; charset=UTF-8',
                    'Content-Transfer-Encoding: quoted-printable',
                    '',
                    quoted_printable_encode(
                        self::normalizeBody(
                            $htmlBody,
                        ),
                    ),
                    '--' . $boundary . '--',
                    '',
                ],
            );
        } else {
            $isHtml = $htmlBody !== null;
            $content = $isHtml
                ? $htmlBody
                : $textBody;

            $headers[] = sprintf(
                'Content-Type: text/%s; charset=UTF-8',
                $isHtml
                    ? 'html'
                    : 'plain',
            );

            $headers[] =
                'Content-Transfer-Encoding: quoted-printable';

            $body = quoted_printable_encode(
                self::normalizeBody(
                    (string) $content,
                ),
            );
        }

        $message = implode(
            "\r\n",
            $headers,
        )
            . "\r\n\r\n"
            . $body;

        $target = sprintf(
            'tcp://%s:%d',
            $host === '::1'
                ? '[::1]'
                : $host,
            $port,
        );

        $errorCode = 0;
        $errorMessage = '';

        $socket = @stream_socket_client(
            $target,
            $errorCode,
            $errorMessage,
            $this->connectTimeoutSeconds,
            STREAM_CLIENT_CONNECT,
        );

        if (!is_resource($socket)) {
            throw new TransportException(
                sprintf(
                    'HeyMail capture SMTP connection failed: %s.',
                    $errorMessage !== ''
                        ? $errorMessage
                        : 'connection refused',
                ),
            );
        }

        stream_set_timeout(
            $socket,
            $this->timeoutSeconds,
        );

        try {
            self::smtpExpect(
                $socket,
                220,
            );

            self::smtpCommand(
                $socket,
                'EHLO heymail-capture.local',
                250,
            );

            self::smtpCommand(
                $socket,
                sprintf(
                    'MAIL FROM:<%s>',
                    $from,
                ),
                250,
            );

            foreach ($recipients as $recipient) {
                self::smtpCommand(
                    $socket,
                    sprintf(
                        'RCPT TO:<%s>',
                        $recipient,
                    ),
                    250,
                );
            }

            self::smtpCommand(
                $socket,
                'DATA',
                354,
            );

            $normalizedMessage = str_replace(
                [
                    "\r\n",
                    "\r",
                ],
                "\n",
                $message,
            );

            $lines = explode(
                "\n",
                $normalizedMessage,
            );

            foreach ($lines as &$line) {
                if (str_starts_with($line, '.')) {
                    $line = '.' . $line;
                }
            }

            unset($line);

            $wireMessage =
                implode(
                    "\r\n",
                    $lines,
                )
                . "\r\n.\r\n";

            if (
                fwrite(
                    $socket,
                    $wireMessage,
                ) === false
            ) {
                throw new TransportException(
                    'HeyMail capture SMTP DATA write failed.',
                );
            }

            self::smtpExpect(
                $socket,
                250,
            );

            self::smtpCommand(
                $socket,
                'QUIT',
                221,
            );
        } finally {
            fclose(
                $socket,
            );
        }

        return [
            'messageId' => null,
            'status' => 'captured',
            'replayed' => false,
            'captureMessageId' => $messageId,
        ];
    }

    /**
     * @return array{string, int}
     */
    private function captureEndpoint(): array
    {
        if ($this->captureDsn === null) {
            throw new RuntimeException(
                'HeyMail capture DSN is not configured.',
            );
        }

        $parts = parse_url(
            $this->captureDsn,
        );

        if (
            !is_array($parts)
            || ($parts['scheme'] ?? null) !== 'smtp'
            || !isset($parts['host'])
            || !is_string($parts['host'])
        ) {
            throw new RuntimeException(
                'HEYMAIL_CAPTURE_DSN must be an smtp:// URL.',
            );
        }

        foreach (
            [
                'user',
                'pass',
                'path',
                'query',
                'fragment',
            ] as $forbidden
        ) {
            if (isset($parts[$forbidden])) {
                throw new RuntimeException(
                    'HEYMAIL_CAPTURE_DSN must not contain credentials, path, query or fragment.',
                );
            }
        }

        $host = strtolower(
            $parts['host'],
        );

        if (
            !in_array(
                $host,
                [
                    '127.0.0.1',
                    'localhost',
                    '::1',
                    'capture',
                ],
                true,
            )
        ) {
            throw new RuntimeException(
                'HEYMAIL_CAPTURE_DSN host must be loopback or the capture service.',
            );
        }

        $port = $parts['port'] ?? 25;

        if (
            !is_int($port)
            || $port < 1
            || $port > 65535
        ) {
            throw new RuntimeException(
                'HEYMAIL_CAPTURE_DSN port is invalid.',
            );
        }

        return [
            $host,
            $port,
        ];
    }

    /**
     * @param array<string, mixed> $payload
     */
    private static function payloadEmail(
        array $payload,
        string $key,
    ): string {
        $value = $payload[$key] ?? null;

        if (!is_array($value)) {
            throw new RuntimeException(
                sprintf(
                    'HeyMail capture %s address is invalid.',
                    $key,
                ),
            );
        }

        return self::arrayEmail(
            $value,
        );
    }

    /**
     * @param array<mixed> $value
     */
    private static function arrayEmail(
        array $value,
    ): string {
        $email = $value['email'] ?? null;

        if (
            !is_string($email)
            || filter_var(
                $email,
                FILTER_VALIDATE_EMAIL,
            ) === false
        ) {
            throw new RuntimeException(
                'HeyMail capture email address is invalid.',
            );
        }

        return $email;
    }

    private static function encodedHeader(
        string $value,
    ): string {
        return sprintf(
            '=?UTF-8?B?%s?=',
            base64_encode(
                $value,
            ),
        );
    }

    private static function rejectHeaderInjection(
        string $value,
    ): void {
        if (
            str_contains(
                $value,
                "\r",
            )
            || str_contains(
                $value,
                "\n",
            )
        ) {
            throw new RuntimeException(
                'HeyMail capture header contains a line break.',
            );
        }
    }

    private static function normalizeBody(
        string $body,
    ): string {
        return str_replace(
            "\n",
            "\r\n",
            str_replace(
                [
                    "\r\n",
                    "\r",
                ],
                "\n",
                $body,
            ),
        );
    }

    /**
     * @param resource $socket
     */
    private static function smtpCommand(
        $socket,
        string $command,
        int $expectedCode,
    ): void {
        if (
            fwrite(
                $socket,
                $command . "\r\n",
            ) === false
        ) {
            throw new TransportException(
                'HeyMail capture SMTP command write failed.',
            );
        }

        self::smtpExpect(
            $socket,
            $expectedCode,
        );
    }

    /**
     * @param resource $socket
     */
    private static function smtpExpect(
        $socket,
        int $expectedCode,
    ): void {
        while (true) {
            $line = fgets(
                $socket,
            );

            if (!is_string($line)) {
                throw new TransportException(
                    'HeyMail capture SMTP connection closed unexpectedly.',
                );
            }

            $line = rtrim(
                $line,
                "\r\n",
            );

            if (
                preg_match(
                    '/^([0-9]{3})([ -])/',
                    $line,
                    $matches,
                ) !== 1
            ) {
                continue;
            }

            $code = (int) $matches[1];

            if ($matches[2] === '-') {
                continue;
            }

            if ($code !== $expectedCode) {
                throw new TransportException(
                    sprintf(
                        'HeyMail capture SMTP expected %d, got %d: %s',
                        $expectedCode,
                        $code,
                        $line,
                    ),
                );
            }

            return;
        }
    }

    private static function environment(
        string $name,
        ?string $default = null,
    ): string {
        $value = self::optionalEnvironment(
            $name,
        );

        if ($value !== null) {
            return $value;
        }

        if ($default !== null) {
            return $default;
        }

        throw new RuntimeException(
            sprintf(
                '%s is required.',
                $name,
            ),
        );
    }

    private static function optionalEnvironment(
        string $name,
    ): ?string {
        $value = getenv(
            $name,
        );

        if (!is_string($value)) {
            return null;
        }

        $value = trim(
            $value,
        );

        return $value !== ''
            ? $value
            : null;
    }

    private static function secretEnvironment(
        string $valueName,
        string $fileName,
    ): string {
        $path = self::optionalEnvironment(
            $fileName,
        );

        if ($path !== null) {
            if (!is_readable($path)) {
                throw new RuntimeException(
                    sprintf(
                        '%s is not readable.',
                        $fileName,
                    ),
                );
            }

            $value = trim(
                (string) file_get_contents(
                    $path,
                ),
            );

            if ($value === '') {
                throw new RuntimeException(
                    sprintf(
                        '%s is empty.',
                        $fileName,
                    ),
                );
            }

            return $value;
        }

        return self::environment(
            $valueName,
        );
    }
}
