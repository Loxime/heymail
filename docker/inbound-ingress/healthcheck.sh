#!/bin/sh

set -eu

postqueue -p \
    >/dev/null 2>&1

python3 - <<'PY'
import socket

for port in (
    25,
    10003,
    10031,
):
    with socket.create_connection(
        ("127.0.0.1", port),
        timeout=2,
    ):
        pass
PY
