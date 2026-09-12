#!/usr/bin/env bash

set -euo pipefail

echo "=== HeyMail DKIM provisioner security tests ==="

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

docker compose config --quiet \
    || fail "Compose configuration is invalid"

COMPOSE_JSON="$(
    docker compose config --format json
)"

python3 -c '
import json
import sys

config = json.load(sys.stdin)
service = config["services"]["dkim-provisioner"]

assert str(service["user"]) == "1000:101"
assert service["read_only"] is True
assert service.get("privileged", False) is False

assert set(service.get("cap_drop") or []) == {
    "ALL",
}

assert not (service.get("cap_add") or [])

assert "no-new-privileges:true" in (
    service.get("security_opt") or []
)

assert set(service.get("networks") or []) == {
    "data_net",
}

assert not service.get("ports")

secrets = {
    item if isinstance(item, str) else item["source"]
    for item in (service.get("secrets") or [])
}

assert secrets == {
    "app_secret",
    "postgres_app_password",
}

private_mounts = [
    volume
    for volume in (service.get("volumes") or [])
    if volume.get("target") == "/run/heymail-dkim"
]

assert len(private_mounts) == 1
assert private_mounts[0].get("read_only", False) is False

command = service["command"]

required = {
    "php",
    "bin/console",
    "messenger:consume",
    "dkim_provisioning",
    "--time-limit=3600",
    "--memory-limit=128M",
    "--sleep=1",
    "--no-interaction",
}

assert required.issubset(set(command))
' <<<"$COMPOSE_JSON" \
    || fail "DKIM provisioner Compose trust boundary is invalid"

pass "Compose trust boundary is valid"

docker compose up \
    -d \
    --force-recreate \
    dkim-provisioner \
    >/dev/null

CONTAINER="$(
    docker compose ps -q dkim-provisioner
)"

[ -n "$CONTAINER" ] \
    || fail "DKIM provisioner container does not exist"

sleep 3

RUNNING="$(
    docker inspect "$CONTAINER" \
        --format '{{.State.Running}}'
)"

[ "$RUNNING" = "true" ] \
    || {
        docker compose logs \
            --tail=100 \
            dkim-provisioner \
            >&2 \
            || true

        fail "DKIM provisioner is not running"
    }

pass "DKIM provisioner starts successfully"

PID1_UID="$(
    docker compose exec -T dkim-provisioner \
        sh -c "awk '/^Uid:/ {print \$2}' /proc/1/status"
)"

PID1_GID="$(
    docker compose exec -T dkim-provisioner \
        sh -c "awk '/^Gid:/ {print \$2}' /proc/1/status"
)"

[ "$PID1_UID" = "1000" ] \
    || fail "unexpected provisioner UID: $PID1_UID"

[ "$PID1_GID" = "101" ] \
    || fail "unexpected provisioner GID: $PID1_GID"

pass "DKIM provisioner runs as UID 1000 / GID 101"

CAP_EFF="$(
    docker compose exec -T dkim-provisioner \
        sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status"
)"

[ "$CAP_EFF" = "0000000000000000" ] \
    || fail "DKIM provisioner has effective capabilities: $CAP_EFF"

NO_NEW_PRIVS="$(
    docker compose exec -T dkim-provisioner \
        sh -c "awk '/^NoNewPrivs:/ {print \$2}' /proc/1/status"
)"

[ "$NO_NEW_PRIVS" = "1" ] \
    || fail "DKIM provisioner lacks no-new-privileges"

pass "DKIM provisioner is capability-free and no-new-privileges constrained"

READ_ONLY="$(
    docker inspect "$CONTAINER" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)"

[ "$READ_ONLY" = "true" ] \
    || fail "DKIM provisioner root filesystem is writable"

pass "DKIM provisioner root filesystem is read-only"

if docker inspect "$CONTAINER" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' \
    | grep -Fxq '/var/run/docker.sock'
then
    fail "Docker socket is exposed to DKIM provisioner"
fi

pass "Docker socket is absent"

NETWORKS="$(
    docker inspect "$CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

[ "$NETWORKS" = "heymail_data" ] \
    || fail "unexpected provisioner networks: $NETWORKS"

INTERNAL="$(
    docker network inspect heymail_data \
        --format '{{.Internal}}'
)"

[ "$INTERNAL" = "true" ] \
    || fail "heymail_data is not internal"

pass "DKIM provisioner belongs only to internal data network"

PORT_BINDINGS="$(
    docker inspect "$CONTAINER" \
        --format '{{json .HostConfig.PortBindings}}'
)"

case "$PORT_BINDINGS" in
    null|"{}")
        ;;
    *)
        fail "DKIM provisioner publishes host ports: $PORT_BINDINGS"
        ;;
esac

pass "DKIM provisioner publishes no host ports"

MOUNT="$(
    docker inspect "$CONTAINER" \
        --format '{{range .Mounts}}{{if eq .Destination "/run/heymail-dkim"}}{{println .Name "|" .RW}}{{end}}{{end}}'
)"

grep -Fq \
    'heymail_rspamd_dkim_private | true' \
    <<<"$MOUNT" \
    || fail "DKIM private volume is not mounted read-write"

pass "DKIM provisioner alone receives writable private DKIM storage"

ROOT_METADATA="$(
    docker compose exec -T dkim-provisioner \
        stat -c '%u:%g:%a' \
        /run/heymail-dkim
)"

[ "$ROOT_METADATA" = "1000:101:770" ] \
    || fail "unexpected DKIM storage metadata: $ROOT_METADATA"

pass "DKIM storage root is restricted to 1000:101/0770"

docker compose exec -T dkim-provisioner \
    sh -c '
        set -eu

        test -r /app/config/packages/mailer.yaml

        probe="/run/heymail-dkim/.security-probe-$$"

        touch "$probe"
        rm -f "$probe"
    ' \
    || fail "provisioner cannot read Symfony config or write DKIM storage"

pass "provisioner can read application config and write only DKIM storage"

docker compose exec -T dkim-provisioner \
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
    || fail "DKIM provisioner unexpectedly has Internet egress"

pass "DKIM provisioner has no direct Internet egress"

docker compose exec -T dkim-provisioner \
    sh -c '
        set -eu

        test -r /run/secrets/app_secret
        test -r /run/secrets/postgres_app_password

        test ! -e /run/secrets/api_key
        test ! -e /run/secrets/api_secret
        test ! -e /run/secrets/payload_kek_v1
        test ! -e /run/secrets/postgres_password
        test ! -e /run/secrets/postgres_migrator_password
    ' \
    || fail "DKIM provisioner secret boundary is incorrect"

pass "DKIM provisioner receives only required runtime secrets"

BAD_PRIVATE_KEYS="$(
    docker compose exec -T dkim-provisioner \
        sh -c '
            find /run/heymail-dkim \
                -mindepth 2 \
                -maxdepth 2 \
                -type f \
                -name "*.key" \
                -exec stat -c "%u:%g:%a %n" {} \;
        ' \
        | awk '$1 != "1000:101:440"'
)"

[ -z "$BAD_PRIVATE_KEYS" ] || {
    printf '%s\n' "$BAD_PRIVATE_KEYS" >&2
    fail "dynamic DKIM private key permissions are unsafe"
}

pass "dynamic DKIM private keys are restricted to 1000:101/0440"

echo
echo "ALL DKIM PROVISIONER SECURITY TESTS PASSED"
