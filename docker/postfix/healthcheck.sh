#!/bin/sh

set -eu

[ "$(cat /proc/1/comm)" = "master" ] || exit 1

kill -0 1 || exit 1

has_process() {
    expected="$1"

    for comm in /proc/[0-9]*/comm
    do
        [ -r "$comm" ] || continue

        name=""

        if IFS= read -r name < "$comm" 2>/dev/null \
            && [ "$name" = "$expected" ]
        then
            return 0
        fi
    done

    return 1
}

has_process pickup
has_process qmgr

exit 0
