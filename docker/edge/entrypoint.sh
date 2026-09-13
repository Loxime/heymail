#!/bin/sh

set -eu

API_KEY="$(
    tr -d '\r\n' \
        < /run/secrets/api_key
)"

API_SECRET="$(
    tr -d '\r\n' \
        < /run/secrets/api_secret
)"

printf '%s\n' "$API_KEY" \
    | grep -Eq '^hm_[a-f0-9]{32}$'

printf '%s\n' "$API_SECRET" \
    | grep -Eq '^[a-f0-9]{64}$'

API_BASIC="$(
    printf '%s:%s' \
        "$API_KEY" \
        "$API_SECRET" \
        | base64 \
        | tr -d '\r\n'
)"

sed \
    "s|__API_BASIC__|${API_BASIC}|g" \
    /etc/nginx/heymail.conf.template \
    > /tmp/nginx.conf

unset \
    API_KEY \
    API_SECRET \
    API_BASIC

exec nginx \
    -e stderr \
    -c /tmp/nginx.conf \
    -g 'daemon off;'
