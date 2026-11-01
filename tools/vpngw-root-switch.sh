#!/bin/bash
set -eo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^(RO|DE|FI)$ ]]; then
    echo "Usage: vpngw-root-switch.sh RO|DE|FI" >&2
    exit 2
fi

location="$1"
config_file="/etc/vpngw-bot.conf"
functions_file="/usr/local/bin/vpngw/vpn-functions.sh"
bypass_script="/usr/local/libexec/vpngw/vpn-bypass-update.sh"
adguard_bin="/opt/adguardvpn_cli/adguardvpn-cli"

if [[ ! -r "$config_file" ]]; then
    echo "Missing bot config: $config_file" >&2
    exit 1
fi
. "$config_file"

if [[ -z "${VPN_IF:-}" || ! "$VPN_IF" =~ ^[[:alnum:]_.-]+$ ]]; then
    echo "Invalid or missing VPN_IF in $config_file" >&2
    exit 1
fi
if [[ ! -x "$adguard_bin" || ! -r "$functions_file" || ! -x "$bypass_script" ]]; then
    echo "Required VPN switch component is missing or not executable" >&2
    exit 1
fi
if [[ "${STATS_DIR:-}" != "/dev/shm/vpn_stats" || -L "/dev/shm/vpn_stats" ]]; then
    echo "Unsafe or missing stats directory: ${STATS_DIR:-unset}" >&2
    exit 1
fi
install -d -o root -g root -m 0700 /dev/shm/vpn_stats
if [[ "$(stat -c '%u:%g:%a' /dev/shm/vpn_stats)" != "0:0:700" ]]; then
    echo "Unable to secure stats directory: /dev/shm/vpn_stats" >&2
    exit 1
fi

"$adguard_bin" connect -l "$location"
VPNGW_FUNCTIONS="$functions_file" "$bypass_script" 8>&-
sleep 5
. "$functions_file"
if ! check_vpn_connectivity "$VPN_IF"; then
    echo "VPN connectivity check failed on $VPN_IF" >&2
    exit 1
fi

printf 'switch:%s\n' "$location"