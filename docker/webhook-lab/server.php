<?php

declare(strict_types=1);

$cert =
    getenv(
        'FAKE_WEBHOOK_CERT_FILE',
    );

$key =
    getenv(
        'FAKE_WEBHOOK_KEY_FILE',
    );

if (
    !is_string($cert)
    || !is_file($cert)
    || !is_string($key)
    || !is_file($key)
) {
    fwrite(
        STDERR,
        "TLS certificate/key missing.\n",
    );

    exit(1);
}

$context =
    stream_context_create([
        'ssl' => [
            'local_cert' => $cert,
            'local_pk' => $key,
            'verify_peer' => false,
            'verify_peer_name' => false,
            'allow_self_signed' => true,
            'disable_compression' => true,
        ],
    ]);

$errno = 0;
$error = '';

$server =
    stream_socket_server(
        'tls://0.0.0.0:9443',
        $errno,
        $error,
        STREAM_SERVER_BIND
        | STREAM_SERVER_LISTEN,
        $context,
    );

if ($server === false) {
    fwrite(
        STDERR,
        sprintf(
            "Unable to start webhook lab: %d %s\n",
            $errno,
            $error,
        ),
    );

    exit(1);
}

file_put_contents(
    '/capture/ready',
    "ready\n",
);

fwrite(
    STDOUT,
    "FAKE_WEBHOOK listening=9443\n",
);

while (
    ($client =
        @stream_socket_accept(
            $server,
            -1,
        ))
    !== false
) {
    stream_set_timeout(
        $client,
        5,
    );

    $requestLine =
        fgets(
            $client,
            8192,
        );

    if (!is_string($requestLine)) {
        fclose(
            $client,
        );

        continue;
    }

    $requestLine =
        trim(
            $requestLine,
        );

    $headers = [];

    while (true) {
        $line =
            fgets(
                $client,
                8192,
            );

        if (!is_string($line)) {
            break;
        }

        $line =
            rtrim(
                $line,
                "\r\n",
            );

        if ($line === '') {
            break;
        }

        $separator =
            strpos(
                $line,
                ':',
            );

        if ($separator === false) {
            continue;
        }

        $name =
            strtolower(
                trim(
                    substr(
                        $line,
                        0,
                        $separator,
                    ),
                ),
            );

        $value =
            trim(
                substr(
                    $line,
                    $separator + 1,
                ),
            );

        $headers[$name] =
            $value;
    }

    $contentLength =
        isset(
            $headers[
                'content-length'
            ],
        )
            ? (int) $headers[
                'content-length'
            ]
            : 0;

    if (
        $contentLength < 0
        || $contentLength > 65536
    ) {
        fwrite(
            $client,
            "HTTP/1.1 413 Payload Too Large\r\n"
            . "Content-Length: 0\r\n"
            . "Connection: close\r\n\r\n",
        );

        fclose(
            $client,
        );

        continue;
    }

    $body = '';

    while (
        strlen($body)
        < $contentLength
    ) {
        $chunk =
            fread(
                $client,
                $contentLength
                - strlen(
                    $body,
                ),
            );

        if (
            !is_string($chunk)
            || $chunk === ''
        ) {
            break;
        }

        $body .=
            $chunk;
    }

    $parts =
        explode(
            ' ',
            $requestLine,
            3,
        );

    $target =
        $parts[1]
        ?? '/';

    $path =
        parse_url(
            $target,
            PHP_URL_PATH,
        );

    if (
        !is_string($path)
        || $path === ''
    ) {
        $path = '/';
    }

    $counterFile =
        '/capture/count-'
        . hash(
            'sha256',
            $path,
        );

    $count =
        is_file(
            $counterFile,
        )
            ? (int) trim(
                (string) file_get_contents(
                    $counterFile,
                ),
            )
            : 0;

    $count++;

    file_put_contents(
        $counterFile,
        (string) $count,
    );

    $status =
        match ($path) {
            '/success'
                => 204,

            '/retry-once'
                => $count === 1
                    ? 500
                    : 204,

            '/dead'
                => 500,

            '/redirect'
                => 302,

            default
                => 404,
        };

    $record = [
        'path' => $path,
        'attempt' => $count,
        'requestLine'
            => $requestLine,
        'headers'
            => $headers,
        'body'
            => $body,
        'status'
            => $status,
    ];

    file_put_contents(
        '/capture/requests.ndjson',
        json_encode(
            $record,
            JSON_THROW_ON_ERROR
            | JSON_UNESCAPED_SLASHES,
        )
        . "\n",
        FILE_APPEND
        | LOCK_EX,
    );

    $reason =
        match ($status) {
            204 => 'No Content',
            302 => 'Found',
            404 => 'Not Found',

            default => 'Internal Server Error',
        };

    $extraHeaders =
        $status === 302
            ? "Location: /success\r\n"
            : '';

    fwrite(
        $client,
        sprintf(
            "HTTP/1.1 %d %s\r\n"
            . "%s"
            . "Content-Length: 0\r\n"
            . "Connection: close\r\n\r\n",
            $status,
            $reason,
            $extraHeaders,
        ),
    );

    fclose(
        $client,
    );
}
