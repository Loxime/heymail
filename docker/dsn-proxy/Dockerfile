# syntax=docker/dockerfile:1

FROM alpine:3.23.5

RUN set -eux; \
    apk add --no-cache socat

USER 65534:65534

ENTRYPOINT ["socat"]

CMD ["TCP-LISTEN:3025,reuseaddr,fork","TCP:dsn-ingress:25"]
