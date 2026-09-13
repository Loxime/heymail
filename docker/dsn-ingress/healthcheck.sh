#!/bin/sh

set -eu

postqueue -p \
    >/dev/null 2>&1

python3 - <<'PY'
import socket

with socket.create_connection(
    ("127.0.0.1", 10031),
    timeout=2,
):
    pass
PY
