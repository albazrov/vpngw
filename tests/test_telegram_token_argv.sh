#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/vpn-functions.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CURL_ARGS_FILE"
ps -eo args > "$PROCESS_LIST_FILE"
tr '\0' '\n' < /proc/self/environ > "$PROCESS_ENV_FILE"
config_file=""
while (($#)); do
    if [[ "$1" == "--config" ]]; then
        config_file="$2"
        shift 2
    else
        shift
    fi
done
printf '%s\n' "${config_file}" > "$CURL_CONFIG_PATH_FILE"
cat "$config_file" > "$CURL_CONFIG_FILE"
EOF
chmod +x "$TEST_DIR/curl"

export PATH="$TEST_DIR:$PATH"
export CURL_CONFIG_PATH_FILE="$TEST_DIR/config-path"
export CURL_ARGS_FILE="$TEST_DIR/args"
export CURL_CONFIG_FILE="$TEST_DIR/config"
export PROCESS_LIST_FILE="$TEST_DIR/process-list"
export PROCESS_ENV_FILE="$TEST_DIR/process-env"
TG_TOKEN='123456789:TEST_TOKEN_MARKER_ABCDEFGHIJKLMNOPQRSTUVWXYZ'
export TG_TOKEN

for endpoint in getUpdates sendMessage answerCallbackQuery; do
    telegram_api_curl "$endpoint" --connect-timeout 3

    if grep -Fq "$TG_TOKEN" "$CURL_ARGS_FILE"; then
        printf 'Telegram token leaked into curl argv for %s\n' "$endpoint" >&2
        exit 1
    fi
    if grep -Fq "$TG_TOKEN" "$PROCESS_LIST_FILE"; then
        printf 'Telegram token leaked into process arguments for %s\n' "$endpoint" >&2
        exit 1
    fi
    if grep -Fq "$TG_TOKEN" "$PROCESS_ENV_FILE"; then
        printf 'Telegram token leaked into process environment for %s\n' "$endpoint" >&2
        exit 1
    fi
    grep -Fq "https://api.telegram.org/bot${TG_TOKEN}/${endpoint}" "$CURL_CONFIG_FILE"
done

if telegram_api_curl unknownEndpoint; then
    printf 'Unexpected Telegram endpoint was accepted\n' >&2
    exit 1
else
    result=$?
    [[ "$result" -eq 2 ]]
fi

TG_TOKEN='invalid token with spaces'
if telegram_api_curl getUpdates; then
    printf 'Malformed Telegram token was accepted\n' >&2
    exit 1
else
    result=$?
    [[ "$result" -eq 78 ]]
fi

printf 'Telegram token argv tests passed\n'
