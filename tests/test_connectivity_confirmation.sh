#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=vpn-functions.sh
source "$ROOT_DIR/vpn-functions.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export VPNGW_CONNECTIVITY_ATTEMPTS=2
export VPNGW_CONNECTIVITY_DELAY=0
export CHECK_TARGETS=("one.example" "two.example")

cat > "$TEST_DIR/ip" <<'EOF'
#!/usr/bin/env bash
count_file="${FAKE_INTERFACE_COUNT_FILE:?}"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$count_file"
if (( count >= ${FAKE_INTERFACE_AVAILABLE_AFTER:-1} )); then
    printf '1: tun0: <POINTOPOINT,UP,LOWER_UP> mtu 1500\n'
    exit 0
fi
exit 1
EOF

cat > "$TEST_DIR/curl" <<'EOF'
#!/usr/bin/env bash
count_file="${FAKE_CURL_COUNT_FILE:?}"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$count_file"
if (( count >= ${FAKE_CURL_SUCCESS_AFTER:-1} )); then
    printf '200'
    exit 0
fi
printf '000'
exit 7
EOF

cat > "$TEST_DIR/ping" <<'EOF'
#!/usr/bin/env bash
count_file="${FAKE_PING_COUNT_FILE:?}"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$count_file"
(( count >= ${FAKE_PING_SUCCESS_AFTER:-1} ))
EOF
chmod +x "$TEST_DIR"/{ip,curl,ping}
export PATH="$TEST_DIR:$PATH"

export FAKE_INTERFACE_COUNT_FILE="$TEST_DIR/ip-count"
export FAKE_INTERFACE_AVAILABLE_AFTER=2
export FAKE_CURL_COUNT_FILE="$TEST_DIR/curl-count"
export FAKE_CURL_SUCCESS_AFTER=1
check_vpn_connectivity tun0

echo 0 > "$TEST_DIR/curl-count"
export FAKE_CURL_SUCCESS_AFTER=99
if check_vpn_connectivity tun0; then
    printf 'Expected repeated VPN probes to fail\n' >&2
    exit 1
fi

export FAKE_PING_COUNT_FILE="$TEST_DIR/ping-count"
export FAKE_PING_SUCCESS_AFTER=2
check_wan_connectivity eth0
[[ "$(<"$FAKE_PING_COUNT_FILE")" -eq 2 ]]

echo 0 > "$TEST_DIR/ping-count"
echo 0 > "$TEST_DIR/curl-count"
export FAKE_PING_SUCCESS_AFTER=99
export FAKE_CURL_SUCCESS_AFTER=1
check_wan_connectivity eth0

export VPNGW_CONNECTIVITY_ATTEMPTS=invalid
if check_vpn_connectivity tun0; then
    printf 'Expected invalid VPN retry settings to fail\n' >&2
    exit 1
else
    result=$?
    [[ "$result" -eq 2 ]]
fi
export VPNGW_CONNECTIVITY_ATTEMPTS=2

connectivity_status_allows_recovery 20 false
connectivity_status_allows_recovery 0 true
if connectivity_status_allows_recovery 0 false; then
    printf 'Healthy VPN with priority checks disabled must not enter recovery\n' >&2
    exit 1
fi
if connectivity_status_allows_recovery 30 true; then
    printf 'Configuration errors must not enter recovery\n' >&2
    exit 1
fi

printf 'Connectivity confirmation tests passed\n'
