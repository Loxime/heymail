<?php

declare(strict_types=1);

namespace App\Mail;

use InvalidArgumentException;
use RuntimeException;

final readonly class UdpDnsTxtRecordResolver
    implements TxtRecordResolver
{
    private const int TYPE_TXT = 16;
    private const int CLASS_IN = 1;

    public function __construct(
        private string $host,
        private int $port,
        private int $timeoutMilliseconds,
    ) {
        if ($this->host === '') {
            throw new InvalidArgumentException(
                'DNS resolver host must not be empty.',
            );
        }

        if (
            $this->port < 1
            || $this->port > 65535
        ) {
            throw new InvalidArgumentException(
                'Invalid DNS resolver port.',
            );
        }

        if (
            $this->timeoutMilliseconds < 1
            || $this->timeoutMilliseconds > 30000
        ) {
            throw new InvalidArgumentException(
                'Invalid DNS resolver timeout.',
            );
        }
    }

    /**
     * @return list<string>
     */
    public function resolve(
        string $name,
    ): array {
        $queryName =
            self::normalizeQueryName(
                $name,
            );

        $transactionId =
            random_int(
                0,
                65535,
            );

        $query =
            pack(
                'nnnnnn',
                $transactionId,
                0x0100,
                1,
                0,
                0,
                0,
            )
            . self::encodeName(
                $queryName,
            )
            . pack(
                'nn',
                self::TYPE_TXT,
                self::CLASS_IN,
            );

        $host = str_contains(
            $this->host,
            ':',
        )
            ? sprintf(
                '[%s]',
                $this->host,
            )
            : $this->host;

        $uri = sprintf(
            'udp://%s:%d',
            $host,
            $this->port,
        );

        $errorCode = 0;
        $errorMessage = '';

        $socket = @stream_socket_client(
            $uri,
            $errorCode,
            $errorMessage,
            $this->timeoutMilliseconds / 1000,
            STREAM_CLIENT_CONNECT,
        );

        if ($socket === false) {
            throw new RuntimeException(
                sprintf(
                    'DNS resolver connection failed (%d).',
                    $errorCode,
                ),
            );
        }

        $seconds = intdiv(
            $this->timeoutMilliseconds,
            1000,
        );

        $microseconds =
            (
                $this->timeoutMilliseconds
                % 1000
            )
            * 1000;

        if (
            !stream_set_timeout(
                $socket,
                $seconds,
                $microseconds,
            )
        ) {
            fclose($socket);

            throw new RuntimeException(
                'DNS resolver timeout configuration failed.',
            );
        }

        $written = fwrite(
            $socket,
            $query,
        );

        if (
            !is_int($written)
            || $written !== strlen($query)
        ) {
            fclose($socket);

            throw new RuntimeException(
                'DNS query could not be sent completely.',
            );
        }

        $response = fread(
            $socket,
            4096,
        );

        $metadata =
            stream_get_meta_data(
                $socket,
            );

        fclose($socket);

        if (
            $metadata['timed_out']
            === true
        ) {
            throw new RuntimeException(
                'DNS query timed out.',
            );
        }

        if (
            !is_string($response)
            || strlen($response) < 12
        ) {
            throw new RuntimeException(
                'DNS resolver returned an invalid response.',
            );
        }

        return self::parseResponse(
            $response,
            $transactionId,
        );
    }

    private static function normalizeQueryName(
        string $name,
    ): string {
        $normalized =
            strtolower(
                rtrim(
                    $name,
                    '.',
                ),
            );

        if (
            $normalized === ''
            || strlen($normalized) > 253
            || preg_match(
                '/[\x00-\x20\x7F]/',
                $normalized,
            ) === 1
        ) {
            throw new InvalidArgumentException(
                'Invalid DNS query name.',
            );
        }

        foreach (
            explode(
                '.',
                $normalized,
            )
            as $label
        ) {
            if (
                $label === ''
                || strlen($label) > 63
                || preg_match(
                    '/^[a-z0-9_-]+$/D',
                    $label,
                ) !== 1
            ) {
                throw new InvalidArgumentException(
                    'Invalid DNS query label.',
                );
            }
        }

        return $normalized;
    }

    private static function encodeName(
        string $name,
    ): string {
        $encoded = '';

        foreach (
            explode(
                '.',
                $name,
            )
            as $label
        ) {
            $encoded .=
                chr(
                    strlen($label),
                )
                . $label;
        }

        return $encoded
            . "\x00";
    }

    /**
     * @return list<string>
     */
    private static function parseResponse(
        string $response,
        int $transactionId,
    ): array {
        if (
            self::readUint16(
                $response,
                0,
            ) !== $transactionId
        ) {
            throw new RuntimeException(
                'DNS response transaction ID mismatch.',
            );
        }

        $flags =
            self::readUint16(
                $response,
                2,
            );

        if (($flags & 0x8000) === 0) {
            throw new RuntimeException(
                'DNS packet is not a response.',
            );
        }

        if (($flags & 0x0200) !== 0) {
            throw new RuntimeException(
                'DNS response is truncated.',
            );
        }

        $responseCode =
            $flags & 0x000F;

        if ($responseCode === 3) {
            return [];
        }

        if ($responseCode !== 0) {
            throw new RuntimeException(
                sprintf(
                    'DNS resolver returned response code %d.',
                    $responseCode,
                ),
            );
        }

        $questionCount =
            self::readUint16(
                $response,
                4,
            );

        $answerCount =
            self::readUint16(
                $response,
                6,
            );

        $offset = 12;

        for (
            $i = 0;
            $i < $questionCount;
            ++$i
        ) {
            self::skipName(
                $response,
                $offset,
            );

            self::requireBytes(
                $response,
                $offset,
                4,
            );

            $offset += 4;
        }

        $records = [];

        for (
            $i = 0;
            $i < $answerCount;
            ++$i
        ) {
            self::skipName(
                $response,
                $offset,
            );

            self::requireBytes(
                $response,
                $offset,
                10,
            );

            $type =
                self::readUint16(
                    $response,
                    $offset,
                );

            $class =
                self::readUint16(
                    $response,
                    $offset + 2,
                );

            $rdLength =
                self::readUint16(
                    $response,
                    $offset + 8,
                );

            $rdataOffset =
                $offset + 10;

            self::requireBytes(
                $response,
                $rdataOffset,
                $rdLength,
            );

            if (
                $type === self::TYPE_TXT
                && $class === self::CLASS_IN
            ) {
                $records[] =
                    self::parseTxtRdata(
                        $response,
                        $rdataOffset,
                        $rdLength,
                    );
            }

            $offset =
                $rdataOffset
                + $rdLength;
        }

        return array_values(
            array_unique(
                $records,
            ),
        );
    }

    private static function readUint16(
        string $data,
        int $offset,
    ): int {
        self::requireBytes(
            $data,
            $offset,
            2,
        );

        return (
            ord($data[$offset])
            << 8
        )
            | ord(
                $data[
                    $offset + 1
                ],
            );
    }

    private static function skipName(
        string $data,
        int &$offset,
    ): void {
        $iterations = 0;

        while (true) {
            if (++$iterations > 128) {
                throw new RuntimeException(
                    'DNS name is malformed.',
                );
            }

            self::requireBytes(
                $data,
                $offset,
                1,
            );

            $length =
                ord(
                    $data[$offset],
                );

            if (
                ($length & 0xC0)
                === 0xC0
            ) {
                self::requireBytes(
                    $data,
                    $offset,
                    2,
                );

                $offset += 2;

                return;
            }

            if (($length & 0xC0) !== 0) {
                throw new RuntimeException(
                    'Unsupported DNS label encoding.',
                );
            }

            ++$offset;

            if ($length === 0) {
                return;
            }

            self::requireBytes(
                $data,
                $offset,
                $length,
            );

            $offset +=
                $length;
        }
    }

    private static function parseTxtRdata(
        string $data,
        int $offset,
        int $length,
    ): string {
        $end =
            $offset
            + $length;

        $value = '';

        while ($offset < $end) {
            self::requireBytes(
                $data,
                $offset,
                1,
            );

            $segmentLength =
                ord(
                    $data[$offset],
                );

            ++$offset;

            if (
                $offset
                + $segmentLength
                > $end
            ) {
                throw new RuntimeException(
                    'Malformed DNS TXT record.',
                );
            }

            $value .= substr(
                $data,
                $offset,
                $segmentLength,
            );

            $offset +=
                $segmentLength;
        }

        return $value;
    }

    private static function requireBytes(
        string $data,
        int $offset,
        int $length,
    ): void {
        if (
            $offset < 0
            || $length < 0
            || $offset + $length
                > strlen($data)
        ) {
            throw new RuntimeException(
                'DNS packet ended unexpectedly.',
            );
        }
    }
}
