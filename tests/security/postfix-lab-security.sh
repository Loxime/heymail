#!/usr/bin/env bash

set -euo pipefail

echo "=== HeyMail Postfix laboratory security tests ==="

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

docker compose config --quiet \
    || fail "Compose configuration is invalid"

docker compose up \
    -d \
    --build \
    --force-recreate \
    fake-mx-success \
    fake-mx-tempfail \
    fake-mx-permfail \
    postfix \
    >/dev/null

POSTFIX_CONTAINER="$(docker compose ps -q postfix)"
API_CONTAINER="$(docker compose ps -q api)"

[ -n "$POSTFIX_CONTAINER" ] \
    || fail "Postfix container does not exist"

# ---------------------------------------------------------------------------
# Network isolation
# ---------------------------------------------------------------------------

NETWORKS="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

EXPECTED_NETWORKS="$(
    printf '%s\n' \
        heymail_filter \
        heymail_smtp_lab \
        | sort
)"

[ "$NETWORKS" = "$EXPECTED_NETWORKS" ] \
    || fail "unexpected Postfix networks: $NETWORKS"

pass "Postfix belongs only to smtp_lab_net and filter_net"

for NETWORK in heymail_filter heymail_smtp_lab
do
    INTERNAL="$(
        docker network inspect "$NETWORK" \
            --format '{{.Internal}}'
    )"

    [ "$INTERNAL" = "true" ] \
        || fail "${NETWORK} is not internal"
done

pass "Postfix networks are both internal"

PORT_BINDINGS="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{json .HostConfig.PortBindings}}'
)"

case "$PORT_BINDINGS" in
    null|"{}")
        ;;
    *)
        fail "Postfix publishes host ports: $PORT_BINDINGS"
        ;;
esac

pass "Postfix publishes no host ports"

# ---------------------------------------------------------------------------
# Docker daemon / privilege boundary currently enforced
# ---------------------------------------------------------------------------

POSTFIX_MOUNT_DESTINATIONS="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{range .Mounts}}{{println .Destination}}{{end}}'
)"

if grep -Fx     '/var/run/docker.sock' \
    <<<"$POSTFIX_MOUNT_DESTINATIONS" \
    >/dev/null
then
    fail "Docker socket is exposed to Postfix"
fi

pass "Docker socket is absent"

SECURITY_OPT="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{json .HostConfig.SecurityOpt}}'
)"

grep -Fq 'no-new-privileges:true' <<<"$SECURITY_OPT" \
    || fail "no-new-privileges is missing"

pass "no-new-privileges is enabled"

PRIVILEGED="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{.HostConfig.Privileged}}'
)"

[ "$PRIVILEGED" = "false" ] \
    || fail "Postfix container is privileged"

pass "Postfix privileged mode is disabled"

CAP_DROP="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{range .HostConfig.CapDrop}}{{println .}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

[ "$CAP_DROP" = "ALL" ] \
    || fail "Postfix does not drop all capabilities before explicit additions"

CAP_ADD="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

EXPECTED_CAP_ADD="$(
    printf '%s\n' \
        CAP_DAC_OVERRIDE \
        CAP_SETGID \
        CAP_SETUID \
        | sort
)"

[ "$CAP_ADD" = "$EXPECTED_CAP_ADD" ] || {
    echo "Expected capabilities:" >&2
    echo "$EXPECTED_CAP_ADD" >&2
    echo "Actual capabilities:" >&2
    echo "$CAP_ADD" >&2
    fail "unexpected Postfix capability set"
}

pass "Postfix capability set is restricted to DAC_OVERRIDE, SETGID and SETUID"

# ---------------------------------------------------------------------------
# Filesystem confinement
# ---------------------------------------------------------------------------

READ_ONLY="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)"

[ "$READ_ONLY" = "true" ] \
    || fail "Postfix root filesystem is not read-only"

pass "Postfix root filesystem is read-only"

docker compose exec -T postfix sh -lc '
if touch /etc/postfix/heymail-security-write-test 2>/dev/null
then
    rm -f /etc/postfix/heymail-security-write-test
    exit 1
fi
' || fail "Postfix can write to its root filesystem"

pass "writes to Postfix root filesystem are effectively blocked"

docker compose exec -T postfix sh -lc '
set -eu

touch /var/lib/postfix/heymail-security-write-test
rm /var/lib/postfix/heymail-security-write-test

touch /var/spool/postfix/heymail-security-write-test
rm /var/spool/postfix/heymail-security-write-test
' || fail "required Postfix writable volumes are unavailable"

pass "required Postfix volumes remain writable"

POSTFIX_MOUNTS="$(
    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{range .Mounts}}{{println .Type .Destination}}{{end}}' \
        | awk 'NF == 2 { print $1 ":" $2 }' \
        | sort
)"

EXPECTED_POSTFIX_MOUNTS="$(
    printf '%s\n' \
        'volume:/var/lib/postfix' \
        'volume:/var/spool/postfix' \
        | sort
)"

[ "$POSTFIX_MOUNTS" = "$EXPECTED_POSTFIX_MOUNTS" ] || {
    echo "Expected writable mounts:" >&2
    echo "$EXPECTED_POSTFIX_MOUNTS" >&2
    echo "Actual mounts:" >&2
    echo "$POSTFIX_MOUNTS" >&2
    fail "unexpected Postfix writable mounts"
}

pass "Postfix writable mounts are restricted to its data and queue volumes"

# ---------------------------------------------------------------------------
# Postfix policy
# ---------------------------------------------------------------------------

POSTCONF="$(
    docker compose exec -T postfix postconf \
        inet_interfaces \
        inet_protocols \
        mynetworks \
        relay_domains \
        relayhost \
        transport_maps \
        default_transport \
        relay_transport \
        non_smtpd_milters \
        smtpd_milters \
        milter_default_action \
        milter_protocol \
        milter_connect_timeout \
        milter_command_timeout \
        milter_content_timeout
)"

grep -Fxq \
    'inet_interfaces = loopback-only' \
    <<<"$POSTCONF" \
    || fail "Postfix is not loopback-only"

grep -Fxq \
    'inet_protocols = ipv4' \
    <<<"$POSTCONF" \
    || fail "unexpected Postfix protocol configuration"

grep -Fxq \
    'mynetworks = 127.0.0.0/8' \
    <<<"$POSTCONF" \
    || fail "unexpected trusted network configuration"

grep -Fxq \
    'transport_maps = pcre:/etc/postfix/transport.pcre' \
    <<<"$POSTCONF" \
    || fail "laboratory transport map is missing"

grep -Fxq \
    'default_transport = error:Outbound delivery outside HeyMail SMTP lab is disabled' \
    <<<"$POSTCONF" \
    || fail "default outbound transport is not blocked"

grep -Fxq \
    'relay_transport = error:Relaying is disabled' \
    <<<"$POSTCONF" \
    || fail "relay transport is not disabled"

pass "Postfix laboratory transport policy is enforced"

grep -Fxq \
    'non_smtpd_milters = inet:rspamd:11332' \
    <<<"$POSTCONF" \
    || fail "Postfix non-SMTP Milter is not Rspamd"

grep -Fxq \
    'smtpd_milters =' \
    <<<"$POSTCONF" \
    || fail "network smtpd Milter policy is unexpectedly enabled"

grep -Fxq \
    'milter_default_action = tempfail' \
    <<<"$POSTCONF" \
    || fail "Postfix Milter failure policy is not tempfail"

grep -Fxq \
    'milter_protocol = 6' \
    <<<"$POSTCONF" \
    || fail "unexpected Postfix Milter protocol"

grep -Fxq \
    'milter_connect_timeout = 5s' \
    <<<"$POSTCONF" \
    || fail "unexpected Postfix Milter connect timeout"

grep -Fxq \
    'milter_command_timeout = 5s' \
    <<<"$POSTCONF" \
    || fail "unexpected Postfix Milter command timeout"

grep -Fxq \
    'milter_content_timeout = 10s' \
    <<<"$POSTCONF" \
    || fail "unexpected Postfix Milter content timeout"

docker compose exec -T postfix \
    sh -lc 'nc -z -w 3 rspamd 11332' \
    || fail "Postfix cannot reach the Rspamd Milter"

pass "Postfix Milter policy is fail-closed and Rspamd is reachable"


# ---------------------------------------------------------------------------
# No network-facing smtpd
# ---------------------------------------------------------------------------

if docker compose exec -T postfix sh -lc '
grep -Eq "^[[:space:]]*smtp[[:space:]]+inet[[:space:]]" \
    /etc/postfix/master.cf
'
then
    fail "network SMTP service is enabled in master.cf"
fi

pass "Postfix network SMTP service is disabled"

if docker compose exec -T fake-mx-success sh -lc '
printf "QUIT\r\n" \
    | socat \
        -T1 \
        - \
        TCP:postfix:25,connect-timeout=1 \
        >/dev/null 2>&1
'
then
    fail "Postfix SMTP port is reachable from another lab container"
fi

pass "Postfix has no reachable SMTP listener"

# ---------------------------------------------------------------------------
# Internet escape
# ---------------------------------------------------------------------------

docker compose exec -T postfix sh -lc '
if wget -T 3 -qO- https://example.com >/dev/null 2>&1
then
    exit 1
fi
' || fail "Postfix has Internet egress"

pass "Postfix has no Internet egress"

# ---------------------------------------------------------------------------
# Symfony remains outside SMTP trust boundary
# ---------------------------------------------------------------------------

API_NETWORKS="$(
    docker inspect "$API_CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

[ "$API_NETWORKS" = "heymail_data" ] \
    || fail "unexpected API networks: $API_NETWORKS"

pass "Symfony API remains isolated from SMTP laboratory"

# ---------------------------------------------------------------------------
# Fake MX confinement
# ---------------------------------------------------------------------------

for SERVICE in \
    fake-mx-success \
    fake-mx-tempfail \
    fake-mx-permfail
do
    CONTAINER="$(
        docker compose ps -q "$SERVICE"
    )"

    USER="$(
        docker inspect "$CONTAINER" \
            --format '{{.Config.User}}'
    )"

    case "$USER" in
        ""|root|0|0:0)
            fail "$SERVICE runs as root"
            ;;
    esac

    READ_ONLY="$(
        docker inspect "$CONTAINER" \
            --format '{{.HostConfig.ReadonlyRootfs}}'
    )"

    [ "$READ_ONLY" = "true" ] \
        || fail "$SERVICE root filesystem is writable"

    CAP_DROP="$(
        docker inspect "$CONTAINER" \
            --format '{{json .HostConfig.CapDrop}}'
    )"

    grep -Fq '"ALL"' <<<"$CAP_DROP" \
        || fail "$SERVICE does not drop all capabilities"

    SERVICE_NETWORKS="$(
        docker inspect "$CONTAINER" \
            --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
            | sed '/^[[:space:]]*$/d' \
            | sort
    )"

    [ "$SERVICE_NETWORKS" = "heymail_smtp_lab" ] \
        || fail "$SERVICE belongs to unexpected networks"

done

pass "fake MX containers are non-root, read-only and capability-free"

echo
echo "ALL POSTFIX LABORATORY SECURITY TESTS PASSED"
