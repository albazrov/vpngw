#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s' "${FAKE_SPEED_BYTES:-1000000}" "${FAKE_HTTP_CODE:-200}"
EOF
chmod +x "$TEST_DIR/curl"
export PATH="$TEST_DIR:$PATH"

# shellcheck source=vpn-functions.sh
source "$ROOT_DIR/vpn-functions.sh"

if FAKE_HTTP_CODE=302 get_vpn_download_speed tun0 custom \
    https://speed.example/file 6 20 speed.example 1.1.1.1 >/dev/null; then
    printf 'Expected redirect response to be rejected\n' >&2
    exit 1
fi

speed=$(FAKE_HTTP_CODE=200 get_vpn_download_speed tun0 custom \
    https://speed.example/file 6 20 speed.example 1.1.1.1)
[[ "$speed" == "7.63" ]]

printf 'Speed test HTTP status checks passed\n'