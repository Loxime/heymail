<?php

declare(strict_types=1);

const DNS_PORT = 8053;
const DNS_TYPE_TXT = 16;
const DNS_CLASS_IN = 1;
const RECORD_FILE = '/records/records.json';

function requireBytes(
    string $data,
    int $offset,
    int $length,
): void {
    if (
        $offset < 0
        || $length < 0
        || $offset + $length > strlen($data)
    ) {
        throw new RuntimeException(
            'Malformed DNS packet.',
        );
    }
}

function readUint16(
    string $data,
    int $offset,
): int {
    requireBytes(
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

function encodeName(
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

function readQuestionName(
    string $packet,
    int &$offset,
): string {
    $labels = [];

    while (true) {
        requireBytes(
            $packet,
            $offset,
            1,
        );

        $length =
            ord(
                $packet[$offset],
            );

        ++$offset;

        if ($length === 0) {
            break;
        }

        if (
            $length > 63
            || ($length & 0xC0) !== 0
        ) {
            throw new RuntimeException(
                'Unsupported DNS query name.',
            );
        }

        requireBytes(
            $packet,
            $offset,
            $length,
        );

        $labels[] =
            substr(
                $packet,
                $offset,
                $length,
            );

        $offset +=
            $length;
    }

    return strtolower(
        implode(
            '.',
            $labels,
        ),
    );
}

/**
 * @return list<string>
 */
function loadRecords(
    string $name,
): array {
    if (!is_readable(RECORD_FILE)) {
        return [];
    }

    $raw =
        file_get_contents(
            RECORD_FILE,
        );

    if (
        !is_string($raw)
        || trim($raw) === ''
    ) {
        return [];
    }

    try {
        $decoded =
            json_decode(
                $raw,
                true,
                32,
                JSON_THROW_ON_ERROR,
            );
    } catch (JsonException) {
        return [];
    }

    if (!is_array($decoded)) {
        return [];
    }

    $values =
        $decoded[$name]
        ?? null;

    if (!is_array($values)) {
        return [];
    }

    $records = [];

    foreach ($values as $value) {
        if (is_string($value)) {
            $records[] =
                $value;
        }
    }

    return $records;
}

function encodeTxtData(
    string $value,
): string {
    if ($value === '') {
        return "\x00";
    }

    $encoded = '';

    foreach (
        str_split(
            $value,
            255,
        )
        as $chunk
    ) {
        $encoded .=
            chr(
                strlen($chunk),
            )
            . $chunk;
    }

    return $encoded;
}

function handleQuery(
    string $packet,
): ?string {
    if (strlen($packet) < 12) {
        return null;
    }

    $transactionId =
        readUint16(
            $packet,
            0,
        );

    $queryFlags =
        readUint16(
            $packet,
            2,
        );

    $questionCount =
        readUint16(
            $packet,
            4,
        );

    if ($questionCount !== 1) {
        return null;
    }

    $offset = 12;

    $name =
        readQuestionName(
            $packet,
            $offset,
        );

    requireBytes(
        $packet,
        $offset,
        4,
    );

    $type =
        readUint16(
            $packet,
            $offset,
        );

    $class =
        readUint16(
            $packet,
            $offset + 2,
        );

    $offset += 4;

    $question =
        substr(
            $packet,
            12,
            $offset - 12,
        );

    $records = [];

    if (
        $type === DNS_TYPE_TXT
        && $class === DNS_CLASS_IN
    ) {
        $records =
            loadRecords(
                $name,
            );
    }

    $flags =
        0x8400
        | ($queryFlags & 0x0100);

    $response =
        pack(
            'nnnnnn',
            $transactionId,
            $flags,
            1,
            count($records),
            0,
            0,
        )
        . $question;

    foreach ($records as $record) {
        $rdata =
            encodeTxtData(
                $record,
            );

        $response .=
            pack(
                'n',
                0xC00C,
            )
            . pack(
                'nnNn',
                DNS_TYPE_TXT,
                DNS_CLASS_IN,
                30,
                strlen($rdata),
            )
            . $rdata;
    }

    return $response;
}

function healthcheck(): void
{
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
        . encodeName(
            '_health.heymail.test',
        )
        . pack(
            'nn',
            DNS_TYPE_TXT,
            DNS_CLASS_IN,
        );

    $errorCode = 0;
    $errorMessage = '';

    $socket =
        @stream_socket_client(
            sprintf(
                'udp://127.0.0.1:%d',
                DNS_PORT,
            ),
            $errorCode,
            $errorMessage,
            1.0,
            STREAM_CLIENT_CONNECT,
        );

    if ($socket === false) {
        exit(1);
    }

    stream_set_timeout(
        $socket,
        1,
        0,
    );

    $written =
        fwrite(
            $socket,
            $query,
        );

    if (
        !is_int($written)
        || $written !== strlen($query)
    ) {
        fclose($socket);
        exit(1);
    }

    $response =
        fread(
            $socket,
            512,
        );

    $metadata =
        stream_get_meta_data(
            $socket,
        );

    fclose($socket);

    if (
        ($metadata['timed_out'] ?? false) === true
        || !is_string($response)
        || strlen($response) < 12
        || readUint16(
            $response,
            0,
        ) !== $transactionId
        || (
            readUint16(
                $response,
                2,
            )
            & 0x8000
        ) === 0
    ) {
        exit(1);
    }

    exit(0);
}

if (
    ($argv[1] ?? null)
    === '--healthcheck'
) {
    healthcheck();
}

$errorCode = 0;
$errorMessage = '';

$server =
    stream_socket_server(
        sprintf(
            'udp://0.0.0.0:%d',
            DNS_PORT,
        ),
        $errorCode,
        $errorMessage,
        STREAM_SERVER_BIND,
    );

if ($server === false) {
    fwrite(
        STDERR,
        sprintf(
            "Fake DNS failed to bind: %s (%d)\n",
            $errorMessage,
            $errorCode,
        ),
    );

    exit(1);
}

while (true) {
    $peer = null;

    $packet =
        stream_socket_recvfrom(
            $server,
            4096,
            0,
            $peer,
        );

    if (
        !is_string($packet)
        || !is_string($peer)
    ) {
        continue;
    }

    try {
        $response =
            handleQuery(
                $packet,
            );
    } catch (Throwable) {
        $response = null;
    }

    if ($response === null) {
        continue;
    }

    stream_socket_sendto(
        $server,
        $response,
        0,
        $peer,
    );
}
