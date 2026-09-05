#!/bin/sh

set -eu

MODE="${FAKE_MX_MODE:-success}"
CR="$(printf '\r')"

case "$MODE" in
    success|tempfail|permfail)
        ;;
    *)
        echo "Unsupported FAKE_MX_MODE: $MODE" >&2
        exit 1
        ;;
esac

reply() {
    printf '%s\r\n' "$1"
}

reply "220 fake-mx-${MODE}.heymail.test ESMTP HeyMail SMTP Lab"

IN_DATA=0

while IFS= read -r LINE
do
    LINE="${LINE%$CR}"

    if [ "$IN_DATA" -eq 1 ]; then
        if [ "$LINE" = "." ]; then
            IN_DATA=0
            reply "250 2.0.0 Message accepted by HeyMail SMTP Lab"
        fi

        continue
    fi

    UPPER="$(
        printf '%s' "$LINE" \
            | tr '[:lower:]' '[:upper:]'
    )"

    case "$UPPER" in
        EHLO\ *|HELO\ *)
            reply "250 fake-mx-${MODE}.heymail.test"
            ;;

        MAIL\ FROM:*)
            reply "250 2.1.0 Sender accepted"
            ;;

        RCPT\ TO:*)
            case "$MODE" in
                success)
                    reply "250 2.1.5 Recipient accepted"
                    ;;

                tempfail)
                    reply "450 4.1.1 Temporary recipient failure"
                    ;;

                permfail)
                    reply "550 5.1.1 Recipient rejected"
                    ;;
            esac
            ;;

        DATA)
            if [ "$MODE" = "success" ]; then
                reply "354 End data with <CR><LF>.<CR><LF>"
                IN_DATA=1
            else
                reply "554 5.5.1 No valid recipients"
            fi
            ;;

        RSET)
            IN_DATA=0
            reply "250 2.0.0 Reset"
            ;;

        NOOP)
            reply "250 2.0.0 OK"
            ;;

        QUIT)
            reply "221 2.0.0 Bye"
            exit 0
            ;;

        *)
            reply "500 5.5.2 Command not recognized"
            ;;
    esac
done
