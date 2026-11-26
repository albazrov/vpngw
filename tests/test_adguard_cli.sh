#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/vpn-functions.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

STATS_DIR="$TEST_DIR"
ensure_stats_dir() { [[ "$STATS_DIR" == "$TEST_DIR" && -d "$STATS_DIR" ]]; }

cat > "$TEST_DIR/adguard-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CAPTURE_FILE"
exit "${FAKE_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_DIR/adguard-cli"

cat > "$TEST_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then shift; fi
if [[ "${1:-}" == "--" ]]; then shift; fi
exec "$@"
EOF
chmod +x "$TEST_DIR/sudo"

export CAPTURE_FILE="$TEST_DIR/arguments"
export ADG_BIN="$TEST_DIR/adguard-cli"
export PATH="$TEST_DIR:$PATH"

run_adguard_connect "DE"
[[ "$(<"$CAPTURE_FILE")" == "connect -l DE" ]]

(
    acquire_vpn_switch_lock
    touch "$TEST_DIR/switch-held"
    while [[ ! -e "$TEST_DIR/release-switch" ]]; do
        sleep 0.02
    done
) &
lock_holder=$!
lock_ready=false
for _ in {1..50}; do
    if [[ -e "$TEST_DIR/switch-held" ]]; then
        lock_ready=true
        break
    fi
    sleep 0.02
done
if [[ "$lock_ready" != true ]]; then
    touch "$TEST_DIR/release-switch"
    wait "$lock_holder"
    printf 'Timed out waiting for VPN switch lock holder\n' >&2
    exit 1
fi

if run_adguard_connect "FI"; then
    touch "$TEST_DIR/release-switch"
    printf 'Expected an already held VPN switch lock to reject connect\n' >&2
    exit 1
else
    result=$?
fi
touch "$TEST_DIR/release-switch"
wait "$lock_holder"
[[ "$result" -eq 75 ]]

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
