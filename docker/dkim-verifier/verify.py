#!/usr/bin/env python3

import os
import re
import sys
from pathlib import Path

import dkim


DOMAIN = os.environ.get(
    "DKIM_VERIFY_DOMAIN",
    "heymail.test",
).rstrip(".").lower()

SELECTOR = os.environ.get(
    "DKIM_VERIFY_SELECTOR",
    "lab",
).rstrip(".").lower()

PUBLIC_KEY = os.environ.get(
    "DKIM_VERIFY_PUBLIC_KEY",
)

PUBLIC_RECORD = Path(
    "/public/heymail.test.lab.dns.txt"
)

EXPECTED_QUERY = (
    f"{SELECTOR}._domainkey.{DOMAIN}"
)


def fail(message: str) -> None:
    print(
        f"DKIM_VERIFY=FAIL reason={message}",
        file=sys.stderr,
    )
    raise SystemExit(1)


if PUBLIC_KEY is not None:
    if not re.fullmatch(
        r"[A-Za-z0-9+/]+={0,2}",
        PUBLIC_KEY,
    ):
        fail(
            "environment DKIM public key is malformed"
        )

    dns_record = (
        f"v=DKIM1; k=rsa; p={PUBLIC_KEY}"
    ).encode("ascii")
else:
    try:
        record_text = PUBLIC_RECORD.read_text(
            encoding="ascii"
        )
    except OSError as exc:
        fail(
            f"cannot read public DKIM record: {exc}"
        )

    chunks = re.findall(
        r'"([^"]*)"',
        record_text,
    )

    if not chunks:
        fail(
            "public DKIM TXT record is empty or malformed"
        )

    dns_record = "".join(
        chunks
    ).encode("ascii")


if not dns_record.startswith(
    b"v=DKIM1;"
):
    fail(
        "public record is not DKIM"
    )

message = sys.stdin.buffer.read()

if not message:
    fail(
        "no message received on stdin"
    )


def dnsfunc(
    name,
    timeout=5,
):
    del timeout

    if isinstance(
        name,
        bytes,
    ):
        query = name.decode(
            "ascii"
        )
    else:
        query = str(
            name
        )

    query = (
        query
        .rstrip(".")
        .lower()
    )

    if query == EXPECTED_QUERY:
        return dns_record

    return None


try:
    valid = dkim.verify(
        message,
        dnsfunc=dnsfunc,
        minkey=2048,
    )
except Exception as exc:
    fail(
        f"verification error: {exc}"
    )

if not valid:
    fail(
        "cryptographic verification failed"
    )

print("DKIM_VERIFY=PASS")
