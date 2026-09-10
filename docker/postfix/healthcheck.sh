#!/bin/sh

set -eu

[ "$(cat /proc/1/comm)" = "master" ] \
    || exit 1

kill -0 1 \
    || exit 1

postqueue -p \
    >/dev/null 2>&1 \
    || exit 1

exit 0
