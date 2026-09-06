#!/bin/sh
set -eu

[ "$(cat /proc/1/comm)" = "rspamd" ] || exit 1

kill -0 1

netstat -lnt 2>/dev/null \
    | grep -Eq '0[.]0[.]0[.]0:11332[[:space:]].*LISTEN'

exit 0
