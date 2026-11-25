#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root: sudo /home/pi/app/vpngw/tools/run-vpngw-remediation.sh" >&2
    exit 1
fi

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DEPLOY_SCRIPT="$ROOT_DIR/tools/pi-bot-deploy-commands.sh"

"$DEPLOY_SCRIPT"

if ! systemctl is-active --quiet vpngw-bot.service; then
    echo "vpngw-bot.service is not active" >&2
    exit 1
fi
if systemctl is-active --quiet vpn-tg-bot.service; then
    echo "legacy vpn-tg-bot.service is still active" >&2
    exit 1
fi
if systemctl is-enabled --quiet vpn-tg-bot.service 2>/dev/null; then
    echo "legacy vpn-tg-bot.service is still enabled" >&2
    exit 1
fi

runtime_state=$(stat -c '%U:%G:%a' /dev/shm/vpn_stats)
if [[ "$runtime_state" != "root:root:700" ]]; then
    echo "Unexpected runtime permissions: $runtime_state" >&2
    exit 1
fi

ROOT_SCRIPTS=(
    adguardvpn-starter.sh
    vpn-auth-helper.sh
    vpn-bypass-update.sh
    vpn-email-send.sh
    vpn-functions.sh
    vpn-hourly-report.sh
    vpn-hw-check.sh
    vpn-loc-update.sh
    vpn-log-sync.sh
    vpn-tg-send.sh
)
for script in "${ROOT_SCRIPTS[@]}"; do
    if ! cmp -s "$ROOT_DIR/$script" "/usr/local/bin/vpngw/$script"; then
        echo "Production script differs from checkout: $script" >&2
        exit 1
    fi
done

if ! crontab -l | awk '
    /\/usr\/local\/bin\/vpngw\// && /\| systemd-cat/ && !/2>&1 \| systemd-cat/ {
        bad=1
    }
    END { exit bad }
'; then
    echo "Root cron still has a vpngw command without stderr journal capture" >&2
    exit 1
fi

# Exercise the normal logging path without initiating a VPN connection.
# shellcheck disable=SC1091
source /etc/vpn-gw.conf
# shellcheck disable=SC1090
source "$MAIN_SH_DIR/vpn-functions.sh"
log_message "Remediation deployment completed; log write verified" "DEPLOY"
flush_vpn_log

echo "VPN gateway remediation deployed and verified."
echo "The VPN location was not changed by this script."
echo "Python bot: $(systemctl is-active vpngw-bot.service)"
echo "Legacy bot: $(systemctl is-active vpn-tg-bot.service 2>/dev/null || true)"
echo "Runtime: $(stat -c '%U:%G %a' /dev/shm/vpn_stats)"
echo "Persistent log: $(stat -c '%U:%G %a %s bytes' "$LOG_DISK")"
