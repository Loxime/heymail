FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN set -eux; \
    apk add --no-cache \
        rspamd=4.0.1-r0; \
    \
    for plugin in /usr/share/rspamd/plugins/*.lua; do \
        module="$(basename "$plugin" .lua)"; \
        printf 'enabled = false;\n' \
            > "/etc/rspamd/override.d/${module}.conf"; \
    done

COPY docker/rspamd/override.d/ /etc/rspamd/override.d/

COPY docker/rspamd/statistic.conf \
    /etc/rspamd/statistic.conf

COPY docker/rspamd/healthcheck.sh \
    /usr/local/bin/heymail-rspamd-healthcheck

COPY docker/rspamd/dkim-bootstrap.sh \
    /usr/local/bin/heymail-rspamd-dkim-bootstrap

RUN set -eux; \
    mkdir -p /run/heymail-dkim; \
    chmod 0555 /run/heymail-dkim; \
    chmod 0555 /usr/local/bin/heymail-rspamd-healthcheck; \
    chmod 0555 /usr/local/bin/heymail-rspamd-dkim-bootstrap; \
    rspamadm configtest

USER 100:101

EXPOSE 11332

ENTRYPOINT ["rspamd"]

CMD ["-f"]
