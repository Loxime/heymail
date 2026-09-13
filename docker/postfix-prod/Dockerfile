# syntax=docker/dockerfile:1

FROM alpine:3.23.5

ARG HEYMAIL_SMTP_HOSTNAME

RUN set -eux; \
    apk add --no-cache \
        postfix \
        ca-certificates; \
    test -n "${HEYMAIL_SMTP_HOSTNAME}"; \
    postconf -e "myhostname = ${HEYMAIL_SMTP_HOSTNAME}"; \
    postconf -e "smtp_helo_name = ${HEYMAIL_SMTP_HOSTNAME}"; \
    postconf -e 'compatibility_level = 3.10'; \
    postconf -e 'inet_protocols = ipv4'; \
    postconf -e 'inet_interfaces = loopback-only'; \
    postconf -e 'mydestination = localhost'; \
    postconf -e 'relay_domains ='; \
    postconf -e 'relayhost ='; \
    postconf -e 'default_transport = smtp'; \
    postconf -e 'relay_transport = smtp'; \
    postconf -e 'transport_maps ='; \
    postconf -e 'smtpd_helo_required = yes'; \
    postconf -e 'disable_vrfy_command = yes'; \
    postconf -e 'mynetworks_style = subnet'; \
    postconf -e 'smtp_tls_security_level = may'; \
    postconf -e 'smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt'; \
    postconf -e 'smtp_tls_loglevel = 1'; \
    postconf -e 'smtp_host_lookup = dns'; \
    postconf -e 'milter_default_action = tempfail'; \
    postconf -e 'milter_protocol = 6'; \
    postconf -e 'milter_connect_timeout = 5s'; \
    postconf -e 'milter_command_timeout = 5s'; \
    postconf -e 'milter_content_timeout = 10s'; \
    postconf -e 'queue_run_delay = 30s'; \
    postconf -e 'minimal_backoff_time = 60s'; \
    postconf -e 'maximal_backoff_time = 600s'; \
    postconf -e 'maximal_queue_lifetime = 2d'; \
    postconf -e 'bounce_queue_lifetime = 1d'; \
    postconf -e 'maillog_file = /var/log/postfix/heymail.log'; \
    postconf -e 'maillog_file_permissions = 0644'; \
    sed -i \
        -E '/^[[:space:]]*smtp[[:space:]]+inet[[:space:]]/s/^/#/' \
        /etc/postfix/master.cf; \
    postconf -M \
        'postfix-mail:10025/inet=postfix-mail:10025 inet n - n - - smtpd'; \
    postconf -P \
        'postfix-mail:10025/inet/syslog_name=postfix/heymail-submission'; \
    postconf -P \
        'postfix-mail:10025/inet/mynetworks=0.0.0.0/0'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_milters=inet:rspamd:11332'; \
    postconf -P \
        'postfix-mail:10025/inet/milter_macro_daemon_name=ORIGINATING'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_client_restrictions=permit_mynetworks,reject'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_relay_restrictions=permit_mynetworks,reject'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_recipient_restrictions=permit'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_sasl_auth_enable=no'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_tls_security_level=none'; \
    mkdir -p /var/log/postfix; \
    touch /var/log/postfix/heymail.log; \
    newaliases

COPY --chmod=0555 \
    docker/postfix-prod/entrypoint.sh \
    /usr/local/bin/heymail-postfix-entrypoint

COPY --chmod=0555 \
    docker/postfix/healthcheck.sh \
    /usr/local/bin/heymail-postfix-healthcheck

ENTRYPOINT ["/usr/local/bin/heymail-postfix-entrypoint"]

CMD ["postfix", "start-fg"]
