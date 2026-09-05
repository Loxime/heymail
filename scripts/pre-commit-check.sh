#!/usr/bin/env bash

set -euo pipefail

echo "[HeyMail] pre-commit secret sanity check"

FAILED=0

# ---------------------------------------------------------------------------
# 1. Basic project checks
# ---------------------------------------------------------------------------

if [[ ! -f ".gitignore" ]]; then
    echo "ERROR: .gitignore is missing."
    FAILED=1
fi

# ---------------------------------------------------------------------------
# 2. Detect whether Git has been initialized
# ---------------------------------------------------------------------------

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_INITIALIZED=true
    echo "OK: Git repository detected."
else
    GIT_INITIALIZED=false
    echo "INFO: Git repository not initialized yet."
fi

# ---------------------------------------------------------------------------
# 3. Protect local .env
# ---------------------------------------------------------------------------

if [[ -f ".env" ]]; then
    if [[ "$GIT_INITIALIZED" == true ]]; then
        if git check-ignore -q -- .env; then
            echo "OK: .env is ignored by Git."
        else
            echo "ERROR: .env exists but is NOT ignored by Git."
            FAILED=1
        fi
    else
        if grep -Eq '^[[:space:]]*\.env[[:space:]]*$' .gitignore; then
            echo "OK: .gitignore contains an explicit .env rule."
            echo "INFO: actual Git ignore behaviour will be verified after git init."
        else
            echo "ERROR: .env exists and no explicit .env rule was found in .gitignore."
            FAILED=1
        fi
    fi
else
    echo "INFO: no local .env file exists."
fi

# ---------------------------------------------------------------------------
# 4. Check files already tracked by Git
# ---------------------------------------------------------------------------

if [[ "$GIT_INITIALIZED" == true ]]; then

    if git ls-files --error-unmatch .env >/dev/null 2>&1; then
        echo "ERROR: .env is already tracked by Git."
        FAILED=1
    else
        echo "OK: .env is not tracked by Git."
    fi

    TRACKED_SECRET_FILES="$(
        git ls-files |
        grep -E '(^|/)([^/]*\.key|[^/]*\.pem|[^/]*\.p12|[^/]*\.pfx|id_rsa[^/]*|id_ed25519[^/]*)$' \
        || true
    )"

    if [[ -n "$TRACKED_SECRET_FILES" ]]; then
        echo "ERROR: potentially sensitive key files are tracked:"
        echo "$TRACKED_SECRET_FILES"
        FAILED=1
    else
        echo "OK: no obvious private-key file is tracked."
    fi

fi

# ---------------------------------------------------------------------------
# 5. Check staged files
# ---------------------------------------------------------------------------

if [[ "$GIT_INITIALIZED" == true ]]; then

    STAGED_FILES="$(git diff --cached --name-only --diff-filter=ACMR || true)"

    if [[ -n "$STAGED_FILES" ]]; then

        BAD_ENV_FILES="$(
            printf '%s\n' "$STAGED_FILES" |
            grep -E '(^|/)\.env($|\.)' |
            grep -Ev '\.example$' \
            || true
        )"

        if [[ -n "$BAD_ENV_FILES" ]]; then
            echo "ERROR: environment secret file staged for commit:"
            echo "$BAD_ENV_FILES"
            FAILED=1
        fi

        BAD_KEY_FILES="$(
            printf '%s\n' "$STAGED_FILES" |
            grep -E '\.(key|pem|p12|pfx|jks|keystore)$' \
            || true
        )"

        if [[ -n "$BAD_KEY_FILES" ]]; then
            echo "ERROR: potentially sensitive key file staged:"
            echo "$BAD_KEY_FILES"
            FAILED=1
        fi

        if git grep --cached -n -I \
            -E -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' \
            >/tmp/heymail-private-key-check 2>/dev/null; then

            echo "ERROR: private key material appears to be staged:"
            cat /tmp/heymail-private-key-check
            FAILED=1
        else
            echo "OK: no private-key header detected in staged content."
        fi

        rm -f /tmp/heymail-private-key-check
    else
        echo "INFO: no files are currently staged."
    fi

fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if [[ "$FAILED" -ne 0 ]]; then
    echo "FAILED: do not commit until the findings are fixed."
    exit 1
fi

echo "OK: no obvious secret-tracking issue detected."
exit 0
