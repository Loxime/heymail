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
        /etc/postfix/master.cf; \
    \
    postconf -M \
        'postfix-mail:10025/inet=postfix-mail:10025 inet n - n - - smtpd'; \
    \
    postconf -P \
        'postfix-mail:10025/inet/syslog_name=postfix/heymail-submission'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_milters=inet:rspamd:11332'; \
    postconf -P \
        'postfix-mail:10025/inet/milter_macro_daemon_name=ORIGINATING'; \
    postconf -e \
        'heymail_submission_relay_restrictions = check_recipient_access pcre:/etc/postfix/submission-recipient-access.pcre, reject'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_relay_restrictions=$heymail_submission_relay_restrictions'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_recipient_restrictions=permit'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_peername_lookup=no'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_sasl_auth_enable=no'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_tls_security_level=none'; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_helo_required=yes'; \
    postconf -P \
        'postfix-mail:10025/inet/disable_vrfy_command=yes'

COPY docker/postfix/transport.pcre \
    /etc/postfix/transport.pcre

COPY docker/postfix/submission-recipient-access.pcre \
    /etc/postfix/submission-recipient-access.pcre

COPY docker/postfix/entrypoint.sh \
    /usr/local/bin/heymail-postfix-entrypoint

COPY docker/postfix/healthcheck.sh \
    /usr/local/bin/heymail-postfix-healthcheck

RUN set -eux; \
    newaliases; \
    test -f /etc/postfix/aliases.lmdb; \
    chmod 0444 /etc/postfix/transport.pcre; \
    chmod 0444 /etc/postfix/submission-recipient-access.pcre; \
    test "$(postmap -q 'probe@success.test' pcre:/etc/postfix/submission-recipient-access.pcre)" = "PERMIT"; \
    test "$(postmap -q 'probe@tempfail.test' pcre:/etc/postfix/submission-recipient-access.pcre)" = "PERMIT"; \
    test "$(postmap -q 'probe@permfail.test' pcre:/etc/postfix/submission-recipient-access.pcre)" = "PERMIT"; \
    test -z "$(postmap -q 'blocked@example.com' pcre:/etc/postfix/submission-recipient-access.pcre)"; \
    chmod 0555 /usr/local/bin/heymail-postfix-entrypoint; \
    chmod 0555 /usr/local/bin/heymail-postfix-healthcheck; \
    postconf -Mf 'postfix-mail:10025/inet' >/dev/null; \
    postconf -P \
        'postfix-mail:10025/inet/smtpd_milters' >/dev/null; \
    postfix check

ENTRYPOINT ["/usr/local/bin/heymail-postfix-entrypoint"]

CMD ["postfix", "start-fg"]
