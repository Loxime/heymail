# syntax=docker/dockerfile:1

FROM node:24-alpine AS web

WORKDIR /src

COPY apps/web/package.json \
     apps/web/package-lock.json \
     ./

RUN npm ci

COPY apps/web/ ./

RUN npm run build


FROM alpine:3.23.5

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
        nginx \
        ca-certificates; \
    rm -rf /etc/nginx/http.d/*

COPY --from=web \
    /src/dist \
    /srv/heymail

COPY --chmod=0555 \
    docker/edge/entrypoint.sh \
    /usr/local/bin/heymail-edge-entrypoint

COPY --chmod=0444 \
    docker/edge/nginx.conf.template \
    /etc/nginx/heymail.conf.template

USER heymail:heymail

ENTRYPOINT ["/usr/local/bin/heymail-edge-entrypoint"]
