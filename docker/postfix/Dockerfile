# syntax=docker/dockerfile:1

FROM alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

RUN set -eux; \
    apk add --no-cache \
        postfix=3.10.13-r0 \
        postfix-pcre=3.10.13-r0 \
        ca-certificates; \
    \
    postconf -e 'compatibility_level = 3.10'; \
    postconf -e 'myhostname = postfix.heymail.test'; \
    postconf -e 'mydomain = heymail.test'; \
    postconf -e 'myorigin = $mydomain'; \
    \
    postconf -e 'inet_interfaces = loopback-only'; \
    postconf -e 'inet_protocols = ipv4'; \
    postconf -e 'mynetworks = 127.0.0.0/8'; \
    \
    postconf -e 'mydestination = localhost'; \
    postconf -e 'relay_domains ='; \
    postconf -e 'relayhost ='; \
    \
    postconf -e 'smtpd_helo_required = yes'; \
    postconf -e 'disable_vrfy_command = yes'; \
    postconf -e 'smtpd_relay_restrictions = reject_unauth_destination'; \
    postconf -e 'smtpd_recipient_restrictions = reject_unauth_destination'; \
    \
    postconf -e 'transport_maps = pcre:/etc/postfix/transport.pcre'; \
    postconf -e 'default_transport = error:Outbound delivery outside HeyMail SMTP lab is disabled'; \
    postconf -e 'relay_transport = error:Relaying is disabled'; \
    \
    postconf -e 'smtp_host_lookup = native'; \
    postconf -e 'smtp_tls_security_level = none'; \
    \
    postconf -e 'non_smtpd_milters = inet:rspamd:11332'; \
    postconf -e 'smtpd_milters ='; \
    postconf -e 'milter_default_action = tempfail'; \
    postconf -e 'milter_protocol = 6'; \
    postconf -e 'milter_connect_timeout = 5s'; \
    postconf -e 'milter_command_timeout = 5s'; \
    postconf -e 'milter_content_timeout = 10s'; \
    \
    postconf -e 'queue_run_delay = 5s'; \
    postconf -e 'minimal_backoff_time = 5s'; \
    postconf -e 'maximal_backoff_time = 30s'; \
    postconf -e 'maximal_queue_lifetime = 5m'; \
    postconf -e 'bounce_queue_lifetime = 5m'; \
    \
    postconf -e 'maillog_file = /dev/stdout'; \
    \
    sed -i \
        -E '/^[[:space:]]*smtp[[:space:]]+inet[[:space:]]/s/^/#/' \
        /etc/postfix/master.cf

COPY docker/postfix/transport.pcre \
    /etc/postfix/transport.pcre

COPY docker/postfix/entrypoint.sh \
    /usr/local/bin/heymail-postfix-entrypoint

COPY docker/postfix/healthcheck.sh \
    /usr/local/bin/heymail-postfix-healthcheck

RUN set -eux; \
    chmod 0444 /etc/postfix/transport.pcre; \
    chmod 0555 /usr/local/bin/heymail-postfix-entrypoint; \
    chmod 0555 /usr/local/bin/heymail-postfix-healthcheck; \
    postfix check

ENTRYPOINT ["/usr/local/bin/heymail-postfix-entrypoint"]

CMD ["postfix", "start-fg"]
