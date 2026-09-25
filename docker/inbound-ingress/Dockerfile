# syntax=docker/dockerfile:1

FROM alpine:3.23.5

ARG HEYMAIL_SMTP_HOSTNAME
ARG HEYMAIL_BOUNCE_DOMAIN
ARG HEYMAIL_INBOUND_DOMAIN
ARG HEYMAIL_SRS_DOMAIN

RUN set -eux; \
    apk add --no-cache \
        ca-certificates \
        postfix \
        postsrsd \
        python3; \
    test -n "${HEYMAIL_SMTP_HOSTNAME}"; \
    test -n "${HEYMAIL_BOUNCE_DOMAIN}"; \
    test -n "${HEYMAIL_INBOUND_DOMAIN}"; \
    test -n "${HEYMAIL_SRS_DOMAIN}"; \
    test "${HEYMAIL_BOUNCE_DOMAIN}" != "${HEYMAIL_INBOUND_DOMAIN}"; \
    test "${HEYMAIL_SRS_DOMAIN}" != "${HEYMAIL_INBOUND_DOMAIN}"; \
    test "${HEYMAIL_SRS_DOMAIN}" != "${HEYMAIL_BOUNCE_DOMAIN}"; \
    postconf -e "myhostname = ${HEYMAIL_SMTP_HOSTNAME}"; \
    postconf -e "smtp_helo_name = ${HEYMAIL_SMTP_HOSTNAME}"; \
    postconf -e 'compatibility_level = 3.10'; \
    postconf -e 'inet_protocols = ipv4'; \
    postconf -e 'inet_interfaces = all'; \
    postconf -e 'mydestination = localhost'; \
    postconf -e "virtual_alias_domains = ${HEYMAIL_INBOUND_DOMAIN}"; \
    postconf -e 'virtual_alias_maps = regexp:/run/heymail/inbound-aliases.regexp'; \
    postconf -e "relay_domains = ${HEYMAIL_BOUNCE_DOMAIN}, ${HEYMAIL_SRS_DOMAIN}"; \
    postconf -e 'transport_maps = regexp:/etc/postfix/heymail-transport.regexp'; \
    postconf -e 'default_transport = smtp'; \
    postconf -e 'relay_transport = smtp'; \
    postconf -e 'smtpd_restriction_classes = heymail_special_recipient_policy'; \
    postconf -e 'heymail_special_recipient_policy = check_policy_service inet:127.0.0.1:10031'; \
    postconf -e 'smtpd_policy_service_timeout = 5s'; \
    postconf -e 'smtpd_policy_service_default_action = 451 4.3.0 Temporary policy failure'; \
    postconf -e 'smtpd_relay_restrictions = reject_unauth_destination'; \
    postconf -e 'smtpd_recipient_restrictions = check_recipient_access regexp:/etc/postfix/heymail-recipient.regexp, reject_unauth_destination'; \
    postconf -e 'smtpd_reject_unlisted_recipient = yes'; \
    postconf -e 'smtpd_helo_required = yes'; \
    postconf -e 'disable_vrfy_command = yes'; \
    postconf -e 'strict_rfc821_envelopes = yes'; \
    postconf -e 'smtpd_sasl_auth_enable = no'; \
    postconf -e 'smtpd_tls_security_level = none'; \
    postconf -e 'smtp_tls_security_level = may'; \
    postconf -e 'smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt'; \
    postconf -e 'smtp_tls_loglevel = 1'; \
    postconf -e 'smtp_host_lookup = dns'; \
    postconf -e 'message_size_limit = 26214400'; \
    postconf -e 'mailbox_size_limit = 0'; \
    postconf -e 'maximal_queue_lifetime = 2d'; \
    postconf -e 'bounce_queue_lifetime = 1d'; \
    postconf -e 'sender_canonical_maps = socketmap:inet:127.0.0.1:10003:forward'; \
    postconf -e 'sender_canonical_classes = envelope_sender'; \
    postconf -e 'recipient_canonical_maps = socketmap:inet:127.0.0.1:10003:reverse'; \
    postconf -e 'recipient_canonical_classes = envelope_recipient,header_recipient'; \
    postconf -e 'smtpd_milters = inet:rspamd:11332'; \
    postconf -e 'milter_default_action = tempfail'; \
    postconf -e 'milter_protocol = 6'; \
    postconf -e 'milter_connect_timeout = 5s'; \
    postconf -e 'milter_command_timeout = 5s'; \
    postconf -e 'milter_content_timeout = 10s'; \
    postconf -e 'maillog_file = /var/log/postfix/heymail-inbound.log'; \
    postconf -e 'maillog_file_permissions = 0644'; \
    BOUNCE_RE="$(printf '%s' "${HEYMAIL_BOUNCE_DOMAIN}" | sed 's/[.]/\\./g')"; \
    SRS_RE="$(printf '%s' "${HEYMAIL_SRS_DOMAIN}" | sed 's/[.]/\\./g')"; \
    printf '/@%s$/ heymail_special_recipient_policy\n/@%s$/ heymail_special_recipient_policy\n' \
        "$BOUNCE_RE" \
        "$SRS_RE" \
        > /etc/postfix/heymail-recipient.regexp; \
    printf '/@%s$/ smtp:[dsn-ingress]:25\n/@%s$/ error:5.1.1 Invalid SRS recipient\n' \
        "$BOUNCE_RE" \
        "$SRS_RE" \
        > /etc/postfix/heymail-transport.regexp; \
    postconf -M 'smtp/inet=smtp inet n - n - - smtpd'; \
    postconf -P 'smtp/inet/syslog_name=postfix/heymail-inbound'; \
    mkdir -p /var/log/postfix; \
    touch /var/log/postfix/heymail-inbound.log; \
    newaliases

COPY --chmod=0555 \
    docker/inbound-ingress/recipient-policy.py \
    /usr/local/bin/heymail-inbound-recipient-policy

COPY --chmod=0555 \
    docker/inbound-ingress/render-aliases.py \
    /usr/local/bin/heymail-render-inbound-aliases

COPY --chmod=0555 \
    docker/inbound-ingress/entrypoint.sh \
    /usr/local/bin/heymail-inbound-entrypoint

COPY --chmod=0555 \
    docker/inbound-ingress/healthcheck.sh \
    /usr/local/bin/heymail-inbound-healthcheck

ENTRYPOINT ["/usr/local/bin/heymail-inbound-entrypoint"]

CMD ["postfix", "start-fg"]
