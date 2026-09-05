# syntax=docker/dockerfile:1

FROM alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

RUN set -eux; \
    apk add --no-cache \
        socat=1.8.1.3-r0; \
    addgroup -S -g 10001 smtp-lab; \
    adduser -S -D -H -u 10001 -G smtp-lab smtp-lab

COPY docker/smtp-lab/fake-mx.sh \
    /usr/local/bin/fake-mx.sh

RUN chmod 0555 /usr/local/bin/fake-mx.sh

USER smtp-lab:smtp-lab

EXPOSE 2525

ENTRYPOINT ["socat", "TCP-LISTEN:2525,reuseaddr,fork", "EXEC:/usr/local/bin/fake-mx.sh"]
