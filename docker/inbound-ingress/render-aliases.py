#!/usr/bin/env python3

import re
import sys


EMAIL_RE = re.compile(
    r"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+"
    r"@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?"
    r"(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$",
    re.IGNORECASE,
)


def fail(message: str) -> None:
    raise SystemExit(
        f"Invalid inbound alias file: {message}"
    )


if len(sys.argv) != 3:
    fail("expected alias file and inbound domain")

path = sys.argv[1]
domain = sys.argv[2].strip().lower()

if not domain or "@" in domain:
    fail("invalid inbound domain")

seen: set[str] = set()
rendered: list[str] = []

with open(
    path,
    "r",
    encoding="utf-8",
) as handle:
    for line_number, raw in enumerate(
        handle,
        start=1,
    ):
        line = raw.strip()

        if not line or line.startswith("#"):
            continue

        parts = line.split()

        if len(parts) != 2:
            fail(
                f"line {line_number}: expected '<source> <destination>'"
            )

        source, destination = (
            item.strip().lower()
            for item in parts
        )

        if (
            EMAIL_RE.fullmatch(source) is None
            or EMAIL_RE.fullmatch(destination) is None
        ):
            fail(
                f"line {line_number}: invalid email address"
            )

        source_local, source_domain = source.rsplit(
            "@",
            1,
        )

        destination_domain = destination.rsplit(
            "@",
            1,
        )[1]

        if source_domain != domain:
            fail(
                f"line {line_number}: source must belong to {domain}"
            )

        if source_local in ("", "*"):
            fail(
                f"line {line_number}: catch-all aliases are forbidden"
            )

        if destination_domain == domain:
            fail(
                f"line {line_number}: forwarding loops are forbidden"
            )

        if source in seen:
            fail(
                f"line {line_number}: duplicate source {source}"
            )

        seen.add(
            source
        )

        rendered.append(
            f"/^{re.escape(source)}$/ {destination}"
        )

if not rendered:
    fail("at least one explicit alias is required")

sys.stdout.write(
    "\n".join(rendered)
    + "\n"
)
