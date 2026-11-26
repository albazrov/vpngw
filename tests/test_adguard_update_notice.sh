#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=vpn-functions.sh
source "$ROOT_DIR/vpn-functions.sh"

notice=$(printf '\033[32mA new version is available: 1.2.3\033[0m\n' |
    extract_adguard_update_notice)
[[ "$notice" == "A new version is available: 1.2.3" ]]

notice=$(printf 'Доступно обновление AdGuard VPN CLI до версии 2.0\n' |
    extract_adguard_update_notice)
[[ "$notice" == "Доступно обновление AdGuard VPN CLI до версии 2.0" ]]

for current_output in \
    "No update is available" \
    "Client is up-to-date" \
    "Обновление не доступно" \
    "Обновлений нет"; do
    if printf '%s\n' "$current_output" | extract_adguard_update_notice; then
        printf 'Expected current-version output to be ignored: %s\n' "$current_output" >&2
        exit 1
    fi
done

printf 'AdGuard update notice tests passed\n'
