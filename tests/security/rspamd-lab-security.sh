#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"

cd "$ROOT_DIR"

ALPINE_IMAGE="alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"

pass() {
    printf 'PASS: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

echo "=== HeyMail Rspamd laboratory security tests ==="

docker compose config --quiet

docker compose up -d --build --force-recreate rspamd

RSPAMD_CONTAINER="$(docker compose ps -q rspamd)"

[ -n "$RSPAMD_CONTAINER" ] \
    || fail "Rspamd container does not exist"

for _ in $(seq 1 60)
do
    HEALTH="$(
        docker inspect "$RSPAMD_CONTAINER" \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
    )"

    if [ "$HEALTH" = "healthy" ]; then
        break
    fi

    [ "$HEALTH" != "unhealthy" ] \
        || fail "Rspamd container is unhealthy"

    sleep 2
done

[ "$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{.State.Health.Status}}'
)" = "healthy" ] \
    || fail "Rspamd did not become healthy"

pass "Rspamd container is healthy"


RSPAMD_VERSION_OUTPUT="$(
    docker exec "$RSPAMD_CONTAINER" \
        rspamd --version
)"

RSPAMD_VERSION="${RSPAMD_VERSION_OUTPUT%%$'\n'*}"

[ "$RSPAMD_VERSION" = "Rspamd daemon version 4.0.1" ] \
    || fail "unexpected Rspamd version: ${RSPAMD_VERSION}"


ALPINE_VERSION="$(
    docker exec "$RSPAMD_CONTAINER"         cat /etc/alpine-release
)"

[ "$ALPINE_VERSION" = "3.24.1" ]     || fail "unexpected Alpine version: ${ALPINE_VERSION}"

pass "Rspamd 4.0.1 runs on Alpine 3.24.1"


RSPAMD_NETWORKS="$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

NETWORK_COUNT="$(
    printf '%s\n' "$RSPAMD_NETWORKS" \
        | sed '/^[[:space:]]*$/d' \
        | wc -l
)"

[ "$NETWORK_COUNT" -eq 1 ] \
    || fail "Rspamd belongs to more than one Docker network"

RSPAMD_NETWORK="$RSPAMD_NETWORKS"

NETWORK_ROLE="$(
    docker network inspect "$RSPAMD_NETWORK" \
        --format '{{index .Labels "com.docker.compose.network"}}'
)"

[ "$NETWORK_ROLE" = "filter_net" ] \
    || fail "Rspamd is not isolated on filter_net"

pass "Rspamd belongs only to filter_net"

[ "$(
    docker network inspect "$RSPAMD_NETWORK" \
        --format '{{.Internal}}'
)" = "true" ] \
    || fail "filter_net is not internal"

pass "filter_net is internal"


[ -z "$(docker port "$RSPAMD_CONTAINER" 2>/dev/null)" ] \
    || fail "Rspamd publishes a host port"

pass "Rspamd publishes no host ports"


if docker inspect "$RSPAMD_CONTAINER" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' \
    | grep -x '/var/run/docker.sock' >/dev/null
then
    fail "Docker socket is exposed to Rspamd"
fi

pass "Docker socket is absent"


[ "$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{.Config.User}}'
)" = "100:101" ] \
    || fail "Rspamd container user is not 100:101"

pass "Rspamd container is configured as non-root (100:101)"


[ "$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{.HostConfig.Privileged}}'
)" = "false" ] \
    || fail "Rspamd container is privileged"

pass "Rspamd privileged mode is disabled"


[ "$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)" = "true" ] \
    || fail "Rspamd root filesystem is writable"

pass "Rspamd root filesystem is read-only"


SECURITY_OPTIONS="$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}'
)"

printf '%s\n' "$SECURITY_OPTIONS" \
    | grep -x 'no-new-privileges:true' >/dev/null \
    || fail "no-new-privileges is disabled"

pass "no-new-privileges is enabled"


CAP_DROP="$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{range .HostConfig.CapDrop}}{{println .}}{{end}}' \
        | sed '/^[[:space:]]*$/d'
)"

[ "$CAP_DROP" = "ALL" ] \
    || fail "Rspamd does not drop all Linux capabilities"

CAP_ADD="$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' \
        | sed '/^[[:space:]]*$/d'
)"

[ -z "$CAP_ADD" ] \
    || fail "Rspamd has Linux capabilities added back"

pass "all Linux capabilities are dropped"


PID1_SECURITY="$(
    docker exec "$RSPAMD_CONTAINER" \
        sh -lc '
            grep -E \
              "^(Uid|Gid|CapPrm|CapEff|CapBnd|NoNewPrivs):" \
              /proc/1/status
        '
)"

printf '%s\n' "$PID1_SECURITY" \
    | grep -E '^Uid:[[:space:]]+100[[:space:]]+100[[:space:]]+100[[:space:]]+100$' >/dev/null \
    || fail "Rspamd PID 1 is not UID 100"

printf '%s\n' "$PID1_SECURITY" \
    | grep -E '^Gid:[[:space:]]+101[[:space:]]+101[[:space:]]+101[[:space:]]+101$' >/dev/null \
    || fail "Rspamd PID 1 is not GID 101"

for CAPABILITY_FIELD in CapPrm CapEff CapBnd
do
    printf '%s\n' "$PID1_SECURITY" \
        | grep -E "^${CAPABILITY_FIELD}:[[:space:]]+0000000000000000$" >/dev/null \
        || fail "Rspamd runtime capability ${CAPABILITY_FIELD} is not zero"
done

printf '%s\n' "$PID1_SECURITY" \
    | grep -E '^NoNewPrivs:[[:space:]]+1$' >/dev/null \
    || fail "Rspamd runtime NoNewPrivs is not active"

pass "Rspamd PID 1 is non-root, capability-free and no-new-privileges constrained"


if docker exec "$RSPAMD_CONTAINER" \
    sh -lc 'touch /etc/rspamd/heymail-rootfs-write-test' \
    >/dev/null 2>&1
then
    fail "Rspamd root filesystem accepted a write"
fi

pass "writes to Rspamd root filesystem are effectively blocked"


docker exec "$RSPAMD_CONTAINER" \
    sh -lc '
        touch /var/lib/rspamd/heymail-state-write-test
        rm /var/lib/rspamd/heymail-state-write-test

        touch /tmp/heymail-tmp-write-test
        rm /tmp/heymail-tmp-write-test
    '

pass "required Rspamd tmpfs paths remain writable"


TMPFS_PATHS="$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{range $path, $_ := .HostConfig.Tmpfs}}{{println $path}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

EXPECTED_TMPFS_PATHS="$(
    printf '%s\n' \
        '/tmp' \
        '/var/lib/rspamd' \
        | sort
)"

[ "$TMPFS_PATHS" = "$EXPECTED_TMPFS_PATHS" ] \
    || fail "unexpected Rspamd tmpfs paths"

pass "Rspamd writable tmpfs paths are restricted to /tmp and /var/lib/rspamd"


LISTENERS="$(
    docker exec "$RSPAMD_CONTAINER" \
        netstat -lnt 2>/dev/null
)"

printf '%s\n' "$LISTENERS" \
    | grep -E '0[.]0[.]0[.]0:11332[[:space:]].*LISTEN' >/dev/null \
    || fail "Rspamd Milter listener 11332 is absent"

if printf '%s\n' "$LISTENERS" \
    | grep -E ':11333 |:11334 |:11335 ' >/dev/null
then
    fail "unnecessary Rspamd listener is active"
fi

pass "only the Rspamd Milter listener is exposed"


PROCESS_LIST="$(
    docker exec "$RSPAMD_CONTAINER" \
        ps -eo args
)"

printf '%s\n' "$PROCESS_LIST" \
    | grep  'rspamd_proxy process' >/dev/null \
    || fail "Rspamd proxy worker is absent"

if printf '%s\n' "$PROCESS_LIST" \
    | grep -E 'rspamd: (normal|controller|fuzzy) process' >/dev/null
then
    fail "an unnecessary Rspamd worker is running"
fi

pass "no unnecessary network-facing Rspamd workers are running"


LOGGING="$(
    docker exec "$RSPAMD_CONTAINER" \
        rspamadm configdump logging 2>/dev/null
)"

printf '%s\n' "$LOGGING" \
    | grep  'type = "console";' >/dev/null \
    || fail "Rspamd logging is not configured for console"

pass "Rspamd logging is console-only"


OPTIONS="$(
    docker exec "$RSPAMD_CONTAINER" \
        rspamadm configdump options 2>/dev/null
)"

printf '%s\n' "$OPTIONS" \
    | grep  'filters = "";' >/dev/null \
    || fail "Rspamd default C filters remain enabled"

printf '%s\n' "$OPTIONS" \
    | grep  'nameserver = "127.0.0.1";' >/dev/null \
    || fail "Rspamd DNS is not constrained to loopback"

printf '%s\n' "$OPTIONS" \
    | grep  'control_socket = "/var/lib/rspamd/rspamd.sock mode=0600";' >/dev/null \
    || fail "Rspamd control socket is outside its writable state area"

pass "Rspamd minimal options policy is enforced"


printf '%s\n' "$OPTIONS"     | grep 'disable_hyperscan = true;' >/dev/null     || fail "Rspamd disable_hyperscan policy is absent"

printf '%s\n' "$OPTIONS"     | grep 'disable_monitoring = true;' >/dev/null     || fail "Rspamd monitoring is enabled"

pass "Rspamd Hyperscan optimization and monitoring policies are constrained"


CLASSIFIER="$(
    docker exec "$RSPAMD_CONTAINER"         rspamadm configdump classifier 2>&1 || true
)"

if printf '%s\n' "$CLASSIFIER"     | grep -E 'backend = "redis"|BAYES_SPAM|BAYES_HAM' >/dev/null
then
    fail "Rspamd Bayes/Redis classifier remains enabled"
fi

pass "Rspamd statistical classifiers are disabled"


echo "Waiting for Rspamd initial multipattern compilation to settle..."

TLD_COMPILATION_COMPLETE=false

for _ in $(seq 1 90)
do
    CURRENT_LOGS="$(
        docker logs "$RSPAMD_CONTAINER" 2>&1
    )"

    if printf '%s\n' "$CURRENT_LOGS" \
        | grep  "received multipattern loaded notification for 'tld'" >/dev/null
    then
        TLD_COMPILATION_COMPLETE=true
        break
    fi

    [ "$(
        docker inspect "$RSPAMD_CONTAINER" \
            --format '{{.State.Running}}'
    )" = "true" ] \
        || fail "Rspamd stopped during initial multipattern compilation"

    [ "$(
        docker inspect "$RSPAMD_CONTAINER" \
            --format '{{.State.OOMKilled}}'
    )" = "false" ] \
        || fail "Rspamd was OOM-killed during initial multipattern compilation"

    sleep 10
done

[ "$TLD_COMPILATION_COMPLETE" = "true" ] \
    || fail "Rspamd TLD multipattern compilation did not finish within 15 minutes"

pass "Rspamd initial TLD multipattern compilation completed"


SETTLED_LOGS="$(
    docker logs "$RSPAMD_CONTAINER" 2>&1
)"

if printf '%s\n' "$SETTLED_LOGS" \
    | grep  'lost [0-9][0-9]* heartbeat from worker type hs_helper' >/dev/null
then
    HEARTBEAT_RECOVERED=false

    for _ in $(seq 1 12)
    do
        SETTLED_LOGS="$(
            docker logs "$RSPAMD_CONTAINER" 2>&1
        )"

        if printf '%s\n' "$SETTLED_LOGS" \
            | grep  'received heartbeat from worker type hs_helper.*beats lost previously' >/dev/null
        then
            HEARTBEAT_RECOVERED=true
            break
        fi

        sleep 5
    done

    [ "$HEARTBEAT_RECOVERED" = "true" ] \
        || fail "Rspamd hs_helper did not recover its heartbeat after compilation"
fi

pass "Rspamd hs_helper is responsive after initial compilation"


[ "$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{.RestartCount}}'
)" -eq 0 ] \
    || fail "Rspamd restarted during the security test"

[ "$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{.State.OOMKilled}}'
)" = "false" ] \
    || fail "Rspamd was OOM-killed"

pass "Rspamd completed startup without restart or OOM"


docker exec "$RSPAMD_CONTAINER" \
    nc -z -w 3 127.0.0.1 11332 \
    || fail "Rspamd Milter became unavailable after initial compilation"

pass "Rspamd Milter remains available after initial compilation"


STATE_USED_KB="$(
    docker exec "$RSPAMD_CONTAINER"         df -k /var/lib/rspamd         | awk 'NR == 2 {print $3}'
)"

[ "$STATE_USED_KB" -le 16384 ]     || fail "Rspamd uses more than half of its 32 MiB state tmpfs"

pass "Rspamd writable state usage remains bounded"


LEGACY_HYPERSCAN_CACHE="$(
    docker exec "$RSPAMD_CONTAINER" \
        sh -lc '
            find /var/lib/rspamd \
              -maxdepth 1 \
              -type f \
              \( \
                -name "*.hsmp" \
                -o -name "*.hsmc" \
                -o -name "*.hsmp.unser" \
              \) \
              -print
        '
)"

[ -z "$LEGACY_HYPERSCAN_CACHE" ] \
    || fail "legacy Rspamd Hyperscan cache files were created"

pass "Rspamd legacy Hyperscan cache regression is absent"


docker exec "$RSPAMD_CONTAINER" \
    grep -qx 'enabled = false;' \
        /etc/rspamd/override.d/dkim_signing.conf \
    || fail "DKIM signing is enabled before key provisioning"

pass "DKIM signing remains disabled"


RSPAMD_LOGS="$(
    docker logs "$RSPAMD_CONTAINER" 2>&1
)"

if printf '%s\n' "$RSPAMD_LOGS"     | grep -F 'No space left on device' >/dev/null
then
    fail "Rspamd exhausted its writable state storage"
fi

pass "Rspamd writable state storage is not exhausted"


if printf '%s\n' "$RSPAMD_LOGS"     | grep -E 'added backend redis for symbol BAYES_|cannot load Redis parameters for the classifier' >/dev/null
then
    fail "Rspamd attempted to initialize Bayes/Redis"
fi

pass "Rspamd performs no Bayes/Redis initialization"


if printf '%s\n' "$RSPAMD_LOGS" \
    | grep -Ei \
      'https?://|network unreachable|address resolution .* failed|monitored.*cannot make request|cannot load map: DNS'
then
    fail "Rspamd attempted external network activity"
fi

pass "no external Rspamd network activity is visible"


docker run --rm \
    --network "$RSPAMD_NETWORK" \
    "$ALPINE_IMAGE" \
    sh -lc 'nc -z -w 3 rspamd 11332'

pass "Rspamd Milter is reachable from the authorized filter network"


for SERVICE in api postfix
do
    SERVICE_CONTAINER="$(docker compose ps -q "$SERVICE" 2>/dev/null || true)"

    [ -n "$SERVICE_CONTAINER" ] || continue

    SERVICE_NETWORKS="$(
        docker inspect "$SERVICE_CONTAINER" \
            --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'
    )"

    if printf '%s\n' "$SERVICE_NETWORKS" \
        | grep -x "$RSPAMD_NETWORK" >/dev/null
    then
        fail "${SERVICE} is prematurely connected to filter_net"
    fi
done

pass "API and Postfix remain isolated from filter_net"


if docker exec "$RSPAMD_CONTAINER" \
    sh -lc '
        timeout 3 wget -qO- http://1.1.1.1 >/dev/null 2>&1
    '
then
    fail "Rspamd has Internet egress"
fi

pass "Rspamd has no Internet egress"


echo
echo "ALL RSPAMD LABORATORY SECURITY TESTS PASSED"
