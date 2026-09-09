# syntax=docker/dockerfile:1

FROM alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

ARG HEYMAIL_UID=1000
ARG HEYMAIL_GID=1000

RUN set -eux; \
    addgroup \
        -g "${HEYMAIL_GID}" \
        -S heymail; \
    adduser \
        -u "${HEYMAIL_UID}" \
        -S \
        -D \
        -G heymail \
        heymail; \
    apk add \
        --no-cache \
        nginx=1.28.3-r7 \
        ca-certificates; \
    rm -rf /etc/nginx/http.d/*

COPY docker/gateway/nginx.conf \
    /etc/nginx/nginx.conf

USER heymail:heymail

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
