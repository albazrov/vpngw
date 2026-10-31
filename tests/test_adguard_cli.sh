#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/vpn-functions.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/adguard-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CAPTURE_FILE"
exit "${FAKE_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_DIR/adguard-cli"

export CAPTURE_FILE="$TEST_DIR/arguments"
export ADG_BIN="$TEST_DIR/adguard-cli"

run_adguard_connect "DE"
[[ "$(<"$CAPTURE_FILE")" == "connect -l DE" ]]

export FAKE_EXIT_CODE=7
if run_adguard_connect "FI"; then
    printf 'Expected fake CLI failure to propagate\n' >&2
    exit 1
else
    result=$?
    [[ "$result" -eq 7 ]]
fi

if run_adguard_connect ""; then
    printf 'Expected empty location to be rejected\n' >&2
    exit 1
else
    result=$?
    [[ "$result" -eq 2 ]]
fi

export ADG_BIN="$TEST_DIR/missing-cli"
if run_adguard_connect "RO"; then
    printf 'Expected missing CLI to be rejected\n' >&2
    exit 1
else
    result=$?
    [[ "$result" -eq 127 ]]
fi

printf 'AdGuard CLI helper tests passed\n'
