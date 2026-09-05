# syntax=docker/dockerfile:1

# ============================================================================
# Dependencies
# ============================================================================

FROM composer:2.10.3@sha256:4d045ea9f71d5d111a95e608400da61d187e487adf9eaf2dfe068998a8d4f584 AS vendor

WORKDIR /app

COPY apps/api/composer.json \
     apps/api/composer.lock \
     apps/api/symfony.lock \
     ./

RUN composer install \
    --no-dev \
    --prefer-dist \
    --no-interaction \
    --no-progress \
    --no-scripts \
    --no-plugins \
    --no-autoloader

COPY apps/api/ /app/

RUN composer dump-autoload \
    --no-dev \
    --classmap-authoritative \
    --no-interaction \
    --no-scripts


# ============================================================================
# Runtime
# ============================================================================

FROM php:8.4.25-fpm-alpine3.23@sha256:097775b7be0425db43dd2eb0879a723d184b47adabac2c47110338a1bee21da0

ARG HEYMAIL_UID=1000
ARG HEYMAIL_GID=1000

RUN set -eux; \
    addgroup -g "${HEYMAIL_GID}" -S heymail; \
    adduser -u "${HEYMAIL_UID}" -S -D -G heymail heymail; \
    apk add --no-cache libpq; \
    apk add --no-cache --virtual .build-deps \
        ${PHPIZE_DEPS} \
        postgresql-dev; \
    docker-php-ext-install -j"$(nproc)" \
        pdo_pgsql \
        opcache; \
    apk del .build-deps

WORKDIR /app

COPY docker/php/heymail.ini \
    /usr/local/etc/php/conf.d/zz-heymail.ini

COPY docker/php/heymail-fpm.conf \
    /usr/local/etc/php-fpm.d/zz-heymail.conf

COPY docker/php/healthcheck.php \
    /usr/local/bin/heymail-healthcheck.php

COPY --from=vendor --chown=heymail:heymail /app /app

RUN set -eux; \
    rm -rf /app/var/*; \
    mkdir -p /app/var; \
    chown heymail:heymail /app/var; \
    chmod 0770 /app/var

USER heymail:heymail

CMD ["php-fpm", "-F"]
