# syntax=docker/dockerfile:1

FROM php:8.4.25-fpm-alpine3.23@sha256:097775b7be0425db43dd2eb0879a723d184b47adabac2c47110338a1bee21da0

RUN set -eux; \
    addgroup \
        -g 10003 \
        -S \
        fake-dns; \
    adduser \
        -u 10003 \
        -S \
        -D \
        -G fake-dns \
        fake-dns

COPY --chmod=0555 \
    docker/dns-lab/fake-dns.php \
    /usr/local/bin/heymail-fake-dns.php

USER 10003:10003

EXPOSE 8053/udp

ENTRYPOINT ["php", "/usr/local/bin/heymail-fake-dns.php"]
