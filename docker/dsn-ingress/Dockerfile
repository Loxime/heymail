# syntax=docker/dockerfile:1

FROM alpine:3.23.5

ARG HEYMAIL_UID=1000
ARG HEYMAIL_GID=1000
ARG HEYMAIL_SMTP_HOSTNAME
ARG HEYMAIL_BOUNCE_DOMAIN

RUN set -eux; \
    apk add --no-cache \
        postfix \
        python3; \
    test -n "${HEYMAIL_SMTP_HOSTNAME}"; \
    test -n "${HEYMAIL_BOUNCE_DOMAIN}"; \
    addgroup \
        -g "${HEYMAIL_GID}" \
        -S heymaildsn; \
    adduser \
        -u "${HEYMAIL_UID}" \
        -S \
        -D \
        -G heymaildsn \
        heymaildsn; \
    postconf -e \
        "myhostname = ${HEYMAIL_SMTP_HOSTNAME}"; \
    postconf -e \
        'compatibility_level = 3.10'; \
    postconf -e \
        'inet_protocols = ipv4'; \
    postconf -e \
        'inet_interfaces = all'; \
    postconf -e \
        'mydestination ='; \
    postconf -e \
        "virtual_mailbox_domains = ${HEYMAIL_BOUNCE_DOMAIN}"; \
    postconf -e \
        'virtual_mailbox_maps = static:1'; \
    postconf -e \
        'virtual_transport = heymail-dsn:'; \
    postconf -e \
        'relay_domains ='; \
    postconf -e \
        'recipient_delimiter ='; \
    postconf -e \
        'smtpd_relay_restrictions = reject_unauth_destination'; \
    postconf -e \
        'smtpd_recipient_restrictions = check_policy_service inet:127.0.0.1:10031,reject_unauth_destination'; \
    IMPORT_ENV="$(postconf -h import_environment)"; \
    EXPORT_ENV="$(postconf -h export_environment)"; \
    postconf -e \
        "import_environment = ${IMPORT_ENV} HEYMAIL_BOUNCE_DOMAIN HEYMAIL_BOUNCE_HMAC_KEY_FILE"; \
    postconf -e \
        "export_environment = ${EXPORT_ENV} HEYMAIL_BOUNCE_DOMAIN HEYMAIL_BOUNCE_HMAC_KEY_FILE"; \
    postconf -e \
        'smtpd_policy_service_timeout = 5s'; \
    postconf -e \
        'smtpd_policy_service_default_action = 451 4.3.0 Temporary policy failure'; \
    postconf -e \
        'smtpd_helo_required = yes'; \
    postconf -e \
        'disable_vrfy_command = yes'; \
    postconf -e \
        'smtpd_sasl_auth_enable = no'; \
    postconf -e \
        'smtpd_tls_security_level = none'; \
    postconf -e \
        'strict_rfc821_envelopes = yes'; \
    postconf -e \
        'message_size_limit = 1048576'; \
    postconf -e \
        'mailbox_size_limit = 0'; \
    postconf -e \
        'maximal_queue_lifetime = 1d'; \
    postconf -e \
        'bounce_queue_lifetime = 1h'; \
    postconf -e \
        'maillog_file = /var/log/postfix/heymail-dsn.log'; \
    postconf -e \
        'maillog_file_permissions = 0640'; \
    postconf -M \
        'smtp/inet=smtp inet n - n - - smtpd'; \
    postconf -P \
        'smtp/inet/syslog_name=postfix/heymail-dsn-ingress'; \
    printf '%s\n' \
        'heymail-dsn unix - n n - - pipe' \
        '  flags=Rq user=heymaildsn argv=/usr/local/bin/heymail-dsn-ingest ${recipient}' \
        >> /etc/postfix/master.cf; \
    newaliases; \
    mkdir -p \
        /var/log/postfix

COPY --chmod=0555 \
    docker/dsn-ingress/recipient-policy.py \
    /usr/local/bin/heymail-dsn-policy

COPY --chmod=0555 \
    docker/dsn-ingress/ingest.py \
    /usr/local/bin/heymail-dsn-ingest

COPY --chmod=0555 \
    docker/dsn-ingress/entrypoint.sh \
    /usr/local/bin/heymail-dsn-entrypoint

COPY --chmod=0555 \
    docker/dsn-ingress/healthcheck.sh \
    /usr/local/bin/heymail-dsn-healthcheck

ENTRYPOINT ["/usr/local/bin/heymail-dsn-entrypoint"]
