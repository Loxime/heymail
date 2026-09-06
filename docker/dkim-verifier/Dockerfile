FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN set -eux; \
    apk add --no-cache \
        py3-dkimpy=1.1.8-r1; \
    addgroup -S -g 10002 dkim-verifier; \
    adduser -S -D -H -u 10002 -G dkim-verifier dkim-verifier

COPY docker/dkim-verifier/verify.py \
    /usr/local/bin/heymail-dkim-verify.py

RUN chmod 0555 /usr/local/bin/heymail-dkim-verify.py

USER 10002:10002

ENTRYPOINT ["python3", "/usr/local/bin/heymail-dkim-verify.py"]
