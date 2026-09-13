#!/usr/bin/env python3

import hashlib
import hmac
import json
import os
import re
import sys
import tempfile

from email import policy
from email.parser import BytesParser


MAX_BYTES = 1048576
EVENT_DIRECTORY = "/events"

DOMAIN = os.environ[
    "HEYMAIL_BOUNCE_DOMAIN"
].strip().lower()

KEY_FILE = os.environ[
    "HEYMAIL_BOUNCE_HMAC_KEY_FILE"
]

RECIPIENT_RE = re.compile(
    r"^bounce\+([1-9][0-9]*)"
    r"\+([a-f0-9]{32})@"
    + re.escape(DOMAIN)
    + r"$"
)

STATUS_RE = re.compile(
    r"^[245]\.[0-9]{1,3}"
    r"\.[0-9]{1,3}$"
)

EMAIL_RE = re.compile(
    r"\b[A-Z0-9._%+-]+"
    r"@[A-Z0-9.-]+\.[A-Z]{2,}\b",
    re.IGNORECASE,
)


def read_key() -> bytes:
    with open(
        KEY_FILE,
        "r",
        encoding="ascii",
    ) as handle:
        encoded = handle.read().strip()

    if not re.fullmatch(
        r"[a-f0-9]{64}",
        encoded,
    ):
        raise RuntimeError(
            "Invalid bounce HMAC key"
        )

    return bytes.fromhex(
        encoded
    )


def authenticate_recipient(
    recipient: str,
) -> int | None:
    match = RECIPIENT_RE.fullmatch(
        recipient.lower()
    )

    if match is None:
        return None

    message_id = int(
        match.group(1)
    )

    payload = (
        "heymail-bounce-v1\0"
        f"{message_id}\0"
        f"{DOMAIN}"
    ).encode("ascii")

    expected = hmac.new(
        read_key(),
        payload,
        hashlib.sha256,
    ).hexdigest()[:32]

    if not hmac.compare_digest(
        match.group(2),
        expected,
    ):
        return None

    return message_id


def recipient_address(
    value: str,
) -> str | None:
    value = str(
        value
    ).strip()

    if ";" in value:
        value = value.split(
            ";",
            1,
        )[1].strip()

    value = value.strip(
        "<>"
    )

    if (
        not value
        or len(value) > 320
        or "@" not in value
        or "\x00" in value
    ):
        return None

    return value.lower()


def clean_detail(
    detail: str,
    recipient: str,
) -> str:
    detail = re.sub(
        r"[\x00-\x1f\x7f]+",
        " ",
        detail,
    )

    detail = re.sub(
        re.escape(recipient),
        "[recipient]",
        detail,
        flags=re.IGNORECASE,
    )

    detail = EMAIL_RE.sub(
        "[recipient]",
        detail,
    )

    detail = " ".join(
        detail.split()
    )

    if not detail:
        detail = "dsn"

    return detail[:1024]


def event_type(
    status: str,
) -> str:
    return {
        "2": "delivered",
        "4": "tempfail",
        "5": "bounced",
    }[status[0]]


def write_event(
    document: dict,
) -> None:
    final_path = os.path.join(
        EVENT_DIRECTORY,
        document[
            "sourceEventId"
        ] + ".json",
    )

    if os.path.exists(
        final_path
    ):
        return

    payload = json.dumps(
        document,
        separators=(
            ",",
            ":",
        ),
        sort_keys=True,
    ).encode("utf-8")

    descriptor, temp_path = tempfile.mkstemp(
        prefix=".heymail-dsn-",
        suffix=".tmp",
        dir=EVENT_DIRECTORY,
    )

    try:
        os.fchmod(
            descriptor,
            0o600,
        )

        handle = os.fdopen(
            descriptor,
            "wb",
        )

        descriptor = -1

        with handle:
            handle.write(
                payload
            )

            handle.flush()

            os.fsync(
                handle.fileno()
            )

        try:
            os.link(
                temp_path,
                final_path,
            )
        except FileExistsError:
            return

        directory_descriptor = os.open(
            EVENT_DIRECTORY,
            os.O_RDONLY,
        )

        try:
            os.fsync(
                directory_descriptor
            )
        finally:
            os.close(
                directory_descriptor
            )
    finally:
        if descriptor >= 0:
            os.close(
                descriptor
            )

        try:
            os.unlink(
                temp_path
            )
        except FileNotFoundError:
            pass

def parse_events(
    raw: bytes,
    message_id: int,
) -> list[dict]:
    message = BytesParser(
        policy=policy.default,
    ).parsebytes(
        raw
    )

    if (
        message.get_content_type()
        != "multipart/report"
        or (
            message.get_param(
                "report-type"
            )
            or ""
        ).lower()
        != "delivery-status"
    ):
        return []

    events = []

    for part in message.walk():
        if (
            part.get_content_type()
            != "message/delivery-status"
        ):
            continue

        payload = part.get_payload()

        if not isinstance(
            payload,
            list,
        ):
            continue

        for block in payload:
            final_recipient = block.get(
                "Final-Recipient"
            )

            status = block.get(
                "Status"
            )

            if (
                final_recipient is None
                or status is None
            ):
                continue

            recipient = recipient_address(
                str(final_recipient)
            )

            status = str(
                status
            ).strip()

            if (
                recipient is None
                or STATUS_RE.fullmatch(
                    status
                )
                is None
            ):
                continue

            action = str(
                block.get(
                    "Action",
                    "",
                )
            ).strip().lower()

            diagnostic = str(
                block.get(
                    "Diagnostic-Code",
                    action
                    or status,
                )
            )

            detail = clean_detail(
                diagnostic,
                recipient,
            )

            recipient_hash = hashlib.sha256(
                recipient.encode(
                    "utf-8"
                )
            ).hexdigest()

            kind = event_type(
                status
            )

            source_payload = (
                "heymail-dsn-v1\0"
                f"{message_id}\0"
                f"{recipient_hash}\0"
                f"{kind}\0"
                f"{status}\0"
                f"{detail}"
            ).encode("utf-8")

            source_event_id = hashlib.sha256(
                source_payload
            ).hexdigest()

            events.append(
                {
                    "messageId":
                        message_id,
                    "recipientHash":
                        recipient_hash,
                    "type":
                        kind,
                    "smtpStatus":
                        status,
                    "detail":
                        detail,
                    "sourceEventId":
                        source_event_id,
                }
            )

    return events


def main() -> int:
    if len(
        sys.argv
    ) != 2:
        return 0

    message_id = authenticate_recipient(
        sys.argv[1]
    )

    if message_id is None:
        return 0

    raw = sys.stdin.buffer.read(
        MAX_BYTES + 1
    )

    if len(raw) > MAX_BYTES:
        return 0

    try:
        events = parse_events(
            raw,
            message_id,
        )

        for document in events:
            write_event(
                document
            )
    except OSError:
        return 75
    except Exception:
        return 0

    return 0


raise SystemExit(
    main()
)
