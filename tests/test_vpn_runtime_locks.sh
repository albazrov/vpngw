#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=vpn-functions.sh
source "$ROOT_DIR/vpn-functions.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

ensure_stats_dir() { [[ "$STATS_DIR" == "$TEST_DIR" ]]; }
export STATS_DIR="$TEST_DIR"
export LOG_RAM="$TEST_DIR/live.log"
export LOG_DISK="$TEST_DIR/persistent.log"
export CLR_CYN=""
export CLR_GRN=""
export CLR_YLW=""
export CLR_RED=""
export CLR_RST=""

(
    acquire_vpn_switch_lock
    printf 'locked\n' > "$TEST_DIR/locked"
    while [[ ! -e "$TEST_DIR/release-lock" ]]; do
        sleep 0.02
    done
) &
holder_pid=$!

ready=false
for _ in {1..50}; do
    if [[ -f "$TEST_DIR/locked" ]]; then
        ready=true
        break
    fi
    sleep 0.02
done
[[ "$ready" == true ]] || {
    printf 'Timed out waiting for VPN lock holder\n' >&2
    exit 1
}

if acquire_vpn_switch_lock; then
    touch "$TEST_DIR/release-lock"
    printf 'Expected a concurrent VPN switch to be rejected\n' >&2
    exit 1
else
    result=$?
    [[ "$result" -eq 75 ]]
fi

touch "$TEST_DIR/release-lock"
wait "$holder_pid"
acquire_vpn_switch_lock
exec 8>&-

for index in {1..20}; do
    (
        log_message "concurrent-$index" "TEST"
    ) &
done
wait

[[ "$(wc -l < "$LOG_RAM")" -eq 20 ]]
flush_vpn_log
[[ ! -s "$LOG_RAM" ]]
[[ "$(wc -l < "$LOG_DISK")" -eq 20 ]]

if grep -q 'vpn-live.log' "$ROOT_DIR/vpn-hourly-report.sh"; then
    printf 'Hourly report must not drain the live VPN log\n' >&2
    exit 1
fi

printf 'VPN runtime lock tests passed\n'
