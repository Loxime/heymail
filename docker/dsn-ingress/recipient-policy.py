#!/usr/bin/env python3

import hashlib
import hmac
import os
import re
import socket
import threading


DOMAIN = os.environ[
    "HEYMAIL_BOUNCE_DOMAIN"
].strip().lower()

KEY_FILE = os.environ[
    "HEYMAIL_BOUNCE_HMAC_KEY_FILE"
]

with open(
    KEY_FILE,
    "r",
    encoding="ascii",
) as handle:
    encoded_key = handle.read().strip()

if not re.fullmatch(
    r"[a-f0-9]{64}",
    encoded_key,
):
    raise SystemExit(
        "Invalid bounce HMAC key"
    )

KEY = bytes.fromhex(
    encoded_key
)

RECIPIENT_RE = re.compile(
    r"^bounce\+([1-9][0-9]*)"
    r"\+([a-f0-9]{32})@"
    + re.escape(DOMAIN)
    + r"$"
)


def valid_recipient(
    recipient: str,
) -> bool:
    match = RECIPIENT_RE.fullmatch(
        recipient.lower()
    )

    if match is None:
        return False

    message_id = int(
        match.group(1)
    )

    provided = match.group(2)

    payload = (
        "heymail-bounce-v1\0"
        f"{message_id}\0"
        f"{DOMAIN}"
    ).encode("ascii")

    expected = hmac.new(
        KEY,
        payload,
        hashlib.sha256,
    ).hexdigest()[:32]

    return hmac.compare_digest(
        provided,
        expected,
    )


def handle_connection(
    connection: socket.socket,
) -> None:
    with connection:
        stream = connection.makefile(
            "rwb",
            buffering=0,
        )

        while True:
            attributes = {}

            while True:
                line = stream.readline()

                if not line:
                    return

                if line in (
                    b"\n",
                    b"\r\n",
                ):
                    break

                text = line.decode(
                    "utf-8",
                    "replace",
                ).rstrip(
                    "\r\n"
                )

                if "=" not in text:
                    continue

                key, value = text.split(
                    "=",
                    1,
                )

                attributes[key] = value

            sender = attributes.get(
                "sender",
                "",
            )

            recipient = attributes.get(
                "recipient",
                "",
            )

            if sender not in (
                "",
                "<>",
            ):
                action = (
                    "REJECT 5.7.1 "
                    "DSN reverse-path must be null"
                )
            elif valid_recipient(
                recipient
            ):
                action = "DUNNO"
            else:
                action = (
                    "REJECT 5.1.1 "
                    "Invalid bounce recipient"
                )

            stream.write(
                (
                    f"action={action}\n\n"
                ).encode("ascii")
            )


server = socket.socket(
    socket.AF_INET,
    socket.SOCK_STREAM,
)

server.setsockopt(
    socket.SOL_SOCKET,
    socket.SO_REUSEADDR,
    1,
)

server.bind(
    (
        "127.0.0.1",
        10031,
    )
)

server.listen(16)

while True:
    connection, _ = server.accept()

    threading.Thread(
        target=handle_connection,
        args=(connection,),
        daemon=True,
    ).start()
