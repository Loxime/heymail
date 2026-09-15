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
    ) {
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
}
