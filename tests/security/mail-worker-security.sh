#!/usr/bin/env bash

set -euo pipefail

echo "=== HeyMail mail-worker security tests ==="

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}


# ---------------------------------------------------------------------------
# Compose / static trust boundary
# ---------------------------------------------------------------------------

docker compose config --quiet \
    || fail "Compose configuration is invalid"

COMPOSE_JSON="$(
    docker compose config --format json
)"

python3 -c '
import json
import sys

config = json.load(sys.stdin)
worker = config["services"]["mail-worker"]
postfix = config["services"]["postfix"]

assert worker["read_only"] is True
assert worker.get("privileged", False) is False
assert set(worker.get("cap_drop") or []) == {"ALL"}

assert "no-new-privileges:true" in (
    worker.get("security_opt") or []
)

assert set(worker.get("networks") or []) == {
    "data_net",
    "mail_net",
}

assert set(postfix.get("networks") or []) == {
    "smtp_lab_net",
    "filter_net",
    "mail_net",
}

mail_network = postfix["networks"]["mail_net"]

assert set(mail_network.get("aliases") or []) == {
    "postfix-mail",
}

mail_services = {
    name
    for name, service in config["services"].items()
    if "mail_net" in (service.get("networks") or {})
}

assert mail_services == {
    "mail-worker",
    "postfix",
}

assert not worker.get("ports")
assert not postfix.get("ports")
assert not worker.get("expose")

secrets = {
    item if isinstance(item, str) else item["source"]
    for item in worker.get("secrets", [])
}

assert secrets == {
    "app_secret",
    "postgres_app_password",
    "payload_kek_v1",
}

environment = worker["environment"]

assert environment["MAILER_DSN"] == (
    "smtp://postfix-mail:10025"
)

assert environment["HEYMAIL_BOUNCE_DOMAIN"] == (
    "heymail.test"
)

assert environment["DB_USER"] == "heymail_app"
assert environment["DB_PASSWORD_FILE"] == (
    "/run/secrets/postgres_app_password"
)

command = worker["command"]

required_command_parts = {
    "php",
    "bin/console",
    "messenger:consume",
    "outbound",
    "--time-limit=3600",
    "--memory-limit=192M",
    "--sleep=1000",
    "--no-interaction",
}

assert required_command_parts.issubset(set(command))
' <<<"$COMPOSE_JSON" \
    || fail "mail-worker Compose trust boundary is invalid"

pass "mail-worker Compose trust boundary is valid"


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

docker compose up \
    -d \
    --build \
    --force-recreate \
    mail-worker \
    postfix \
    >/dev/null

WORKER_CONTAINER="$(
    docker compose ps -q mail-worker
)"

[ -n "$WORKER_CONTAINER" ] \
    || fail "mail-worker container does not exist"

sleep 5

RUNNING="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{.State.Running}}'
)"

[ "$RUNNING" = "true" ] \
    || {
        docker compose logs --tail=100 mail-worker >&2 || true
        fail "mail-worker is not running"
    }

RESTART_COUNT="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{.RestartCount}}'
)"

[ "$RESTART_COUNT" = "0" ] \
    || fail "mail-worker unexpectedly restarted ($RESTART_COUNT)"

pass "mail-worker starts and remains stable"


# ---------------------------------------------------------------------------
# Process identity
# ---------------------------------------------------------------------------

PID1_COMMAND="$(
    docker compose exec -T mail-worker \
        sh -c 'tr "\0" " " < /proc/1/cmdline'
)"

grep -Fq \
    'php bin/console messenger:consume outbound' \
    <<<"$PID1_COMMAND" \
    || fail "PID 1 is not the outbound Messenger consumer"

grep -Fq \
    -- '--time-limit=3600' \
    <<<"$PID1_COMMAND" \
    || fail "worker time limit is missing"

grep -Fq \
    -- '--memory-limit=192M' \
    <<<"$PID1_COMMAND" \
    || fail "worker memory limit is missing"

pass "PID 1 is the bounded outbound Messenger consumer"


# ---------------------------------------------------------------------------
# Non-root / Linux privilege confinement
# ---------------------------------------------------------------------------

PID1_UID="$(
    docker compose exec -T mail-worker \
        sh -c "awk '/^Uid:/ {print \$2}' /proc/1/status"
)"

[ "$PID1_UID" != "0" ] \
    || fail "mail-worker PID 1 runs as root"

PID1_GID="$(
    docker compose exec -T mail-worker \
        sh -c "awk '/^Gid:/ {print \$2}' /proc/1/status"
)"

CAP_EFF="$(
    docker compose exec -T mail-worker \
        sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status"
)"

[ "$CAP_EFF" = "0000000000000000" ] \
    || fail "mail-worker has effective Linux capabilities: $CAP_EFF"

NO_NEW_PRIVS="$(
    docker compose exec -T mail-worker \
        sh -c "awk '/^NoNewPrivs:/ {print \$2}' /proc/1/status"
)"

[ "$NO_NEW_PRIVS" = "1" ] \
    || fail "mail-worker PID 1 lacks no-new-privileges"

pass "mail-worker runs non-root and capability-free (UID $PID1_UID GID $PID1_GID)"


# ---------------------------------------------------------------------------
# Filesystem confinement
# ---------------------------------------------------------------------------

READ_ONLY="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)"

[ "$READ_ONLY" = "true" ] \
    || fail "mail-worker root filesystem is not read-only"

docker compose exec -T mail-worker sh -c '
if touch /heymail-worker-forbidden-write 2>/dev/null
then
    rm -f /heymail-worker-forbidden-write
    exit 1
fi
' || fail "mail-worker can write to root filesystem"

docker compose exec -T mail-worker sh -c '
set -eu

touch /tmp/heymail-worker-security-test
touch /app/var/heymail-worker-security-test

rm -f \
    /tmp/heymail-worker-security-test \
    /app/var/heymail-worker-security-test
' || fail "mail-worker restricted writable paths are unavailable"

pass "mail-worker filesystem confinement is effective"


# ---------------------------------------------------------------------------
# Docker daemon isolation
# ---------------------------------------------------------------------------

if docker inspect "$WORKER_CONTAINER" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' \
    | grep -Fxq '/var/run/docker.sock'
then
    fail "Docker socket is exposed to mail-worker"
fi

pass "Docker socket is absent"


# ---------------------------------------------------------------------------
# Host port / listener isolation
# ---------------------------------------------------------------------------

PORT_BINDINGS="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{json .HostConfig.PortBindings}}'
)"

case "$PORT_BINDINGS" in
    null|"{}")
        ;;
    *)
        fail "mail-worker publishes host ports: $PORT_BINDINGS"
        ;;
esac

pass "mail-worker publishes no host ports"

# The PHP base image contains EXPOSE 9000 metadata, but the worker must not
# actually run PHP-FPM or listen on that port.
if docker compose exec -T mail-worker \
    php -r '
        $errno = 0;
        $error = "";

        $socket = @fsockopen(
            "127.0.0.1",
            9000,
            $errno,
            $error,
            1.0
        );

        if (is_resource($socket)) {
            fclose($socket);
            exit(1);
        }
    '
then
    pass "inherited PHP-FPM port metadata has no active listener"
else
    fail "mail-worker unexpectedly exposes a listener on container port 9000"
fi


# ---------------------------------------------------------------------------
# Network confinement
# ---------------------------------------------------------------------------

NETWORKS="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

EXPECTED_NETWORKS=$'heymail_data\nheymail_mail'

[ "$NETWORKS" = "$EXPECTED_NETWORKS" ] \
    || fail "unexpected mail-worker networks: $NETWORKS"

DATA_INTERNAL="$(
    docker network inspect heymail_data \
        --format '{{.Internal}}'
)"

[ "$DATA_INTERNAL" = "true" ] \
    || fail "heymail_data is not an internal Docker network"

MAIL_INTERNAL="$(
    docker network inspect heymail_mail \
        --format '{{.Internal}}'
)"

[ "$MAIL_INTERNAL" = "true" ] \
    || fail "heymail_mail is not an internal Docker network"

pass "mail-worker belongs only to internal heymail_data and heymail_mail"


POSTFIX_IP="$(
    docker compose exec -T mail-worker \
        php -r '
            $ip = gethostbyname("postfix");

            if ($ip === "postfix") {
                exit(1);
            }

            echo $ip;
        '
)" || fail "postfix is not resolvable from mail-worker"

[ -n "$POSTFIX_IP" ] \
    || fail "postfix resolved to an empty address"

pass "postfix is reachable through mail_net DNS ($POSTFIX_IP)"


docker compose exec -T mail-worker \
    php -r '
        $errno = 0;
        $error = "";

        $socket = @fsockopen(
            "postfix",
            25,
            $errno,
            $error,
            1.0,
        );

        if (is_resource($socket)) {
            fclose($socket);
            exit(1);
        }
    ' \
    || fail "Postfix unexpectedly accepts SMTP on port 25"

pass "standard SMTP port 25 remains closed"


SUBMISSION_BANNER="$(
    docker compose exec -T mail-worker \
        php -r '
            $errno = 0;
            $error = "";

            $socket = @fsockopen(
                "postfix-mail",
                10025,
                $errno,
                $error,
                2.0,
            );

            if (!is_resource($socket)) {
                fwrite(
                    STDERR,
                    sprintf(
                        "connect failed: %d %s\n",
                        $errno,
                        $error,
                    ),
                );

                exit(1);
            }

            stream_set_timeout($socket, 2);

            $banner = fgets($socket);

            fclose($socket);

            if (
                !is_string($banner)
                || !str_starts_with($banner, "220 ")
            ) {
                exit(1);
            }

            echo trim($banner);
        '
)" || fail "internal Postfix submission listener is unavailable"

pass "internal SMTP submission listener answered: $SUBMISSION_BANNER"


POSTFIX_CONTAINER="$(
    docker compose ps -q postfix
)"

[ -n "$POSTFIX_CONTAINER" ] \
    || fail "Postfix container does not exist"

POSTFIX_MAIL_IP="$(
    docker inspect "$POSTFIX_CONTAINER" \
        | python3 -c '
import json
import sys

data = json.load(sys.stdin)[0]

print(
    data["NetworkSettings"]["Networks"]
        ["heymail_mail"]["IPAddress"]
)
'
)"

[ -n "$POSTFIX_MAIL_IP" ] \
    || fail "Postfix has no heymail_mail address"

BOUND_10025="$(
    docker compose exec -T postfix \
        cat /proc/net/tcp \
        | python3 -c '
import socket
import sys

listeners = set()

for line in sys.stdin:
    fields = line.split()

    if len(fields) < 4:
        continue

    local = fields[1]
    state = fields[3]

    if state != "0A":
        continue

    address_hex, port_hex = local.split(":", 1)

    if int(port_hex, 16) != 10025:
        continue

    raw = bytes.fromhex(address_hex)

    listeners.add(
        socket.inet_ntoa(raw[::-1])
    )

for listener in sorted(listeners):
    print(listener)
'
)"

[ "$BOUND_10025" = "$POSTFIX_MAIL_IP" ] \
    || fail \
        "submission listener bind mismatch: expected $POSTFIX_MAIL_IP, got ${BOUND_10025:-none}"

pass "port 10025 is bound only to the Postfix mail_net address"


RELAY_POLICY="$(
    docker compose exec -T postfix \
        postconf -P \
        'postfix-mail:10025/inet/smtpd_relay_restrictions'
)"

grep -Fq \
    ' = $heymail_submission_relay_restrictions' \
    <<<"$RELAY_POLICY" \
    || fail "submission listener does not use dedicated relay policy"

RELAY_RESTRICTIONS="$(
    docker compose exec -T postfix \
        postconf \
        heymail_submission_relay_restrictions
)"

grep -Fq \
    'check_recipient_access pcre:/etc/postfix/submission-recipient-access.pcre, reject' \
    <<<"$RELAY_RESTRICTIONS" \
    || fail "submission relay restriction chain is unsafe"

for RECIPIENT in \
    probe@success.test \
    probe@tempfail.test \
    probe@permfail.test
do
    RESULT="$(
        docker compose exec -T postfix \
            postmap -q \
            "$RECIPIENT" \
            pcre:/etc/postfix/submission-recipient-access.pcre
    )"

    [ "$RESULT" = "PERMIT" ] \
        || fail "laboratory recipient is not permitted: $RECIPIENT"
done

BLOCKED_RESULT=""

if BLOCKED_RESULT="$(
    docker compose exec -T postfix \
        postmap -q \
        blocked@example.com \
        pcre:/etc/postfix/submission-recipient-access.pcre
)"; then
    :
else
    STATUS=$?

    [ "$STATUS" -eq 1 ] \
        || fail "submission recipient lookup failed ($STATUS)"
fi

[ -z "$BLOCKED_RESULT" ] \
    || fail "non-laboratory recipient matched submission allowlist"

pass "submission listener permits only SMTP laboratory destinations"


RELAY_REJECT_CODE="$(
    docker compose exec -T mail-worker \
        php -r '
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

                return 0;
            };

            $send = static function (
                $socket,
                string $command,
                int $expected,
            ) use ($readResponse): void {
                fwrite(
                    $socket,
                    $command . "\r\n",
                );

                if ($readResponse($socket) !== $expected) {
                    exit(2);
                }
            };

            $errno = 0;
            $error = "";

            $socket = @fsockopen(
                "postfix-mail",
                10025,
                $errno,
                $error,
                2.0,
            );

            if (!is_resource($socket)) {
                exit(3);
            }

            stream_set_timeout($socket, 5);

            if ($readResponse($socket) !== 220) {
                fclose($socket);
                exit(4);
            }

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

            fwrite(
                $socket,
                "RCPT TO:<blocked@example.com>\r\n",
            );

            $code = $readResponse($socket);

            fwrite($socket, "QUIT\r\n");
            fclose($socket);

            echo $code;
        '
)" || fail "relay rejection probe failed"

grep -Eq '^5[0-9]{2}$' <<<"$RELAY_REJECT_CODE" \
    || fail \
        "non-laboratory destination was not rejected: SMTP $RELAY_REJECT_CODE"

pass "submission listener rejects non-laboratory relay destinations"


for HOST in \
    rspamd \
    fake-mx-success
do
    docker compose exec -T mail-worker \
        php -r '
            $host = $argv[1];

            if (gethostbyname($host) !== $host) {
                exit(1);
            }
        ' "$HOST" \
        || fail "$HOST is unexpectedly resolvable from mail-worker"

    pass "$HOST is absent from mail-worker network namespace"
done


# Direct external TCP egress must also fail on an internal Docker network.
docker compose exec -T mail-worker \
    php -r '
        $errno = 0;
        $error = "";

        $socket = @fsockopen(
            "1.1.1.1",
            443,
            $errno,
            $error,
            1.0
        );

        if (is_resource($socket)) {
            fclose($socket);
            exit(1);
        }
    ' \
    || fail "mail-worker unexpectedly has direct Internet egress"

pass "mail-worker has no direct Internet egress"


# ---------------------------------------------------------------------------
# Secret boundary
# ---------------------------------------------------------------------------

docker compose exec -T mail-worker sh -c '
set -eu

test -r /run/secrets/app_secret
test -r /run/secrets/postgres_app_password
test -r /run/secrets/payload_kek_v1

test ! -e /run/secrets/postgres_password
test ! -e /run/secrets/postgres_migrator_password
' || fail "mail-worker secret boundary is incorrect"

pass "mail-worker receives only application runtime secrets"

ENV_DUMP="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{range .Config.Env}}{{println .}}{{end}}'
)"

grep -Fxq \
    'APP_SECRET_FILE=/run/secrets/app_secret' \
    <<<"$ENV_DUMP" \
    || fail "APP_SECRET_FILE path is missing"

grep -Fxq \
    'DB_PASSWORD_FILE=/run/secrets/postgres_app_password' \
    <<<"$ENV_DUMP" \
    || fail "DB password secret path is missing"

grep -Fxq \
    'PAYLOAD_KEK_FILE=/run/secrets/payload_kek_v1' \
    <<<"$ENV_DUMP" \
    || fail "payload KEK secret path is missing"

pass "mail-worker environment contains secret paths, not passwords"


# ---------------------------------------------------------------------------
# Database / Messenger identity
# ---------------------------------------------------------------------------

DB_USER="$(
    docker compose exec -T mail-worker \
        php bin/console dbal:run-sql \
        'SELECT current_user' \
        --no-interaction
)"

grep -Eq \
    '(^|[[:space:]])heymail_app([[:space:]]|$)' \
    <<<"$DB_USER" \
    || fail "mail-worker does not connect as heymail_app"

if grep -Eq \
    'heymail_migrator|heymail_admin' \
    <<<"$DB_USER"
then
    fail "mail-worker uses a privileged PostgreSQL role"
fi

pass "mail-worker database identity is restricted to heymail_app"


MESSENGER_STATS="$(
    docker compose exec -T mail-worker \
        php bin/console messenger:stats \
        outbound \
        failed \
        --format=json
)" || fail "mail-worker cannot access Messenger transports"

python3 -c '
import json
import sys

stats = json.load(sys.stdin)["transports"]

for transport in ("outbound", "failed"):
    count = stats[transport]["count"]

    assert isinstance(count, int)
    assert count >= 0
' <<<"$MESSENGER_STATS" \
    || fail "Messenger transport statistics are invalid"

pass "mail-worker can access outbound and failed Messenger queues"


# ---------------------------------------------------------------------------
# Runtime stability
# ---------------------------------------------------------------------------

RUNNING="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{.State.Running}}'
)"

RESTART_COUNT="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{.RestartCount}}'
)"

[ "$RUNNING" = "true" ] \
    || fail "mail-worker stopped during security tests"

[ "$RESTART_COUNT" = "0" ] \
    || fail "mail-worker restarted during security tests"

pass "mail-worker remained stable throughout security tests"


echo
echo "ALL MAIL-WORKER SECURITY TESTS PASSED"
