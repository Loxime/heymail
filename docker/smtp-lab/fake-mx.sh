#!/bin/sh

set -eu

MODE="${FAKE_MX_MODE:-success}"
CAPTURE_DIR="${FAKE_MX_CAPTURE_DIR:-}"

CR="$(printf '\r')"

CAPTURE_TMP=""

case "$MODE" in
    success|tempfail|permfail)
        ;;
    *)
        echo "Unsupported FAKE_MX_MODE: $MODE" >&2
        exit 1
        ;;
esac

if [ -n "$CAPTURE_DIR" ]; then
    [ "$MODE" = "success" ] || {
        echo "Capture is only supported in success mode" >&2
        exit 1
    }

    [ -d "$CAPTURE_DIR" ] || {
        echo "Capture directory does not exist" >&2
        exit 1
    }

    [ -w "$CAPTURE_DIR" ] || {
        echo "Capture directory is not writable" >&2
        exit 1
    }
fi

umask 077

reply() {
    printf '%s\r\n' "$1"
}

cleanup_capture() {
    if [ -n "$CAPTURE_TMP" ]; then
        rm -f "$CAPTURE_TMP"
        CAPTURE_TMP=""
    fi
}

begin_capture() {
    cleanup_capture

    if [ -n "$CAPTURE_DIR" ]; then
        CAPTURE_TMP="${CAPTURE_DIR}/message.$$.tmp"

        : > "$CAPTURE_TMP"
        chmod 0600 "$CAPTURE_TMP"
    fi
}

finish_capture() {
    if [ -n "$CAPTURE_TMP" ]; then
        mv -f \
            "$CAPTURE_TMP" \
            "${CAPTURE_DIR}/last.eml"

        CAPTURE_TMP=""
    fi
}

trap cleanup_capture EXIT HUP INT TERM

reply "220 fake-mx-${MODE}.heymail.test ESMTP HeyMail SMTP Lab"

IN_DATA=0

while IFS= read -r LINE
do
    LINE="${LINE%$CR}"

    if [ "$IN_DATA" -eq 1 ]; then
        if [ "$LINE" = "." ]; then
            IN_DATA=0
            finish_capture

            reply "250 2.0.0 Message accepted by HeyMail SMTP Lab"

            continue
        fi

        # SMTP dot-unstuffing:
        # "..foo" on the wire represents ".foo" in the message.
        case "$LINE" in
            ..*)
                LINE="${LINE#.}"
                ;;
        esac

        if [ -n "$CAPTURE_TMP" ]; then
            printf '%s\r\n' "$LINE" \
                >> "$CAPTURE_TMP"
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
                begin_capture
                IN_DATA=1

                reply "354 End data with <CR><LF>.<CR><LF>"
            else
                reply "554 5.5.1 No valid recipients"
            fi
            ;;

        RSET)
            IN_DATA=0
            cleanup_capture

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
