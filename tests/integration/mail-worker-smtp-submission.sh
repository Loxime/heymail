#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"

cd "$ROOT_DIR"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

clear_capture() {
    docker compose exec -T fake-mx-success \
        rm -f /capture/last.eml \
        >/dev/null 2>&1 \
        || true
}

wait_for_capture() {
    local marker="$1"

    for _ in $(seq 1 30)
    do
        if docker compose exec -T fake-mx-success \
            grep -aF "$marker" \
            /capture/last.eml \
            >/dev/null 2>&1
        then
            return 0
        fi

        sleep 1
    done

    return 1
}

echo "=== HeyMail worker SMTP submission integration test ==="

docker compose config --quiet \
    || fail "Compose configuration is invalid"

docker compose build \
    dkim-verifier \
    >/dev/null

docker compose up \
    -d \
    --wait \
    --build \
    fake-mx-success \
    rspamd \
    postfix \
    mail-worker \
    >/dev/null

clear_capture

RUN_ID="$(date +%s)-$$"
RECIPIENT="worker-${RUN_ID}@success.test"
SUBJECT="HeyMail worker SMTP ${RUN_ID}"
BODY_MARKER="WORKER-SMTP-DKIM-${RUN_ID}"

docker compose exec -T mail-worker \
    php -r '
        $recipient = $argv[1];
        $subject = $argv[2];
        $marker = $argv[3];

        $readResponse = static function ($socket): int {
            while (($line = fgets($socket)) !== false) {
                if (
                    preg_match(
                        "/^([0-9]{3})([ -])/",
                        $line,
                        $matches,
                    ) === 1
                    && $matches[2] === " "
                ) {
                    return (int) $matches[1];
                }
            }

            $meta = stream_get_meta_data($socket);

            if ($meta["timed_out"] ?? false) {
                fwrite(
                    STDERR,
                    "SMTP response read timed out\n",
                );

                return -1;
            }

            if (feof($socket)) {
                fwrite(
                    STDERR,
                    "SMTP connection closed before response\n",
                );

                return -2;
            }

            return 0;
        };

        $expect = static function (
            $socket,
            int $expected,
        ) use ($readResponse): void {
            $actual = $readResponse($socket);

            if ($actual !== $expected) {
                fwrite(
                    STDERR,
                    sprintf(
                        "SMTP expected %d, got %d\n",
                        $expected,
                        $actual,
                    ),
                );

                exit(1);
            }
        };

        $send = static function (
            $socket,
            string $command,
            int $expected,
        ) use ($expect): void {
            fwrite(
                $socket,
                $command . "\r\n",
            );

            $expect(
                $socket,
                $expected,
            );
        };

        $errno = 0;
        $error = "";

        $socket = @fsockopen(
            "postfix-mail",
            10025,
            $errno,
            $error,
            3.0,
        );

        if (!is_resource($socket)) {
            fwrite(
                STDERR,
                sprintf(
                    "SMTP connection failed: %d %s\n",
                    $errno,
                    $error,
                ),
            );

            exit(1);
        }

        stream_set_timeout(
            $socket,
            70,
        );

        $expect(
            $socket,
            220,
        );

        $send(
            $socket,
            "EHLO mail-worker.heymail.test",
            250,
        );

        $send(
            $socket,
            "MAIL FROM:<worker@heymail.test>",
            250,
        );

        $send(
            $socket,
            "RCPT TO:<" . $recipient . ">",
            250,
        );

        $send(
            $socket,
            "DATA",
            354,
        );

        $message = implode(
            "\r\n",
            [
                "From: worker@heymail.test",
                "To: " . $recipient,
                "Subject: " . $subject,
                "Date: " . gmdate(DATE_RFC2822),
                "Message-ID: <" . bin2hex(random_bytes(16))
                    . "@heymail.test>",
                "",
                $marker,
                "",
                ".",
                "",
            ],
        );

        fwrite(
            $socket,
            $message,
        );

        $expect(
            $socket,
            250,
        );

        fwrite(
            $socket,
            "QUIT\r\n",
        );

        fclose($socket);
    ' \
    "$RECIPIENT" \
    "$SUBJECT" \
    "$BODY_MARKER" \
    || fail "worker SMTP transaction failed"

pass "mail-worker submitted message through postfix-mail:10025"

wait_for_capture "$BODY_MARKER" \
    || fail "message did not reach fake-mx-success"

pass "SMTP-submitted message reached fake MX"

docker compose exec -T fake-mx-success \
    grep -a '^DKIM-Signature:' \
    /capture/last.eml \
    >/dev/null \
    || fail "SMTP-submitted message has no DKIM signature"

pass "SMTP-submitted message contains DKIM-Signature"

docker compose exec -T fake-mx-success \
    cat /capture/last.eml \
    | docker compose run \
        --rm \
        --no-deps \
        -T \
        dkim-verifier \
    || fail "SMTP-submitted DKIM signature is invalid"

pass "SMTP-submitted DKIM signature is cryptographically valid"

SUBMISSION_OBSERVED="false"
SUBMISSION_QUEUE_ID=""

for _ in $(seq 1 20)
do
    POSTFIX_LOGS="$(
        docker compose logs \
            --no-color \
            postfix \
            2>/dev/null \
            || true
    )"

    DELIVERY_LINE="$(
        grep -F \
            -- "to=<${RECIPIENT}>" \
            <<<"$POSTFIX_LOGS" \
            | tail -n 1 \
            || true
    )"

    SUBMISSION_QUEUE_ID="$(
        sed -nE \
            's/.*postfix\/smtp\[[0-9]+\]: ([A-Z0-9]+):.*/\1/p' \
            <<<"$DELIVERY_LINE"
    )"

    if [ -n "$SUBMISSION_QUEUE_ID" ]; then
        SUBMISSION_LINE="$(
            grep -F \
                'postfix/heymail-submission/smtpd' \
                <<<"$POSTFIX_LOGS" \
                | grep -F \
                    "${SUBMISSION_QUEUE_ID}: client=" \
                | tail -n 1 \
                || true
        )"

        if [ -n "$SUBMISSION_LINE" ]; then
            SUBMISSION_OBSERVED="true"
            break
        fi
    fi

    sleep 0.5
done

[ "$SUBMISSION_OBSERVED" = "true" ] \
    || fail \
        "current message was not correlated with dedicated submission smtpd"

pass \
    "message queue ${SUBMISSION_QUEUE_ID} used dedicated HeyMail submission smtpd"

if docker compose exec -T postfix \
    postqueue -p \
    | grep -F "$RECIPIENT" \
    >/dev/null
then
    fail "success.test message remains in Postfix queue"
fi

pass "successful submission left no queued test message"

echo
echo "ALL WORKER SMTP SUBMISSION TESTS PASSED"
