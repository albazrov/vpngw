#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash /home/pi/app/vpngw/tools/pi-bot-deploy-commands.sh" >&2
  exit 1
fi

if [[ -z "${TG_TOKEN:-}" && ! -f /etc/vpngw-bot.env ]]; then
  echo "Set TG_TOKEN for a new install, or provide the existing /etc/vpngw-bot.env." >&2
  exit 1
fi

if ! id -u vpngw-bot >/dev/null 2>&1; then
  useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin vpngw-bot
fi
chmod 0711 /home/pi

install -d -o root -g root -m 0755 /usr/local/bin/vpngw /usr/local/libexec/vpngw
install -d -o root -g root -m 0755 /etc/tmpfiles.d
install -o root -g root -m 0644 /home/pi/app/vpngw/deploy/vpngw-tmpfiles.conf.example /etc/tmpfiles.d/vpngw.conf
systemd-tmpfiles --create /etc/tmpfiles.d/vpngw.conf
install -o root -g root -m 0644 /home/pi/app/vpngw/vpn-functions.sh /usr/local/bin/vpngw/vpn-functions.sh
if [[ ! -f /etc/vpngw-speed-tests.conf ]]; then
  install -o root -g vpngw-bot -m 0640 /home/pi/app/vpngw/vpn-speed-tests.conf.example /etc/vpngw-speed-tests.conf
fi
chown root:vpngw-bot /etc/vpngw-speed-tests.conf
chmod 0640 /etc/vpngw-speed-tests.conf
install -o root -g root -m 0755 /home/pi/app/vpngw/vpn-bypass-update.sh /usr/local/libexec/vpngw/vpn-bypass-update.sh
install -o root -g root -m 0755 /home/pi/app/vpngw/tools/vpngw-root-switch.sh /usr/local/sbin/vpngw-root-switch
install -o root -g root -m 0440 /home/pi/app/vpngw/python_bot/systemd/vpngw-bot.sudoers /etc/sudoers.d/vpngw-bot
visudo -cf /etc/sudoers.d/vpngw-bot

install -d -o root -g root -m 0700 /etc/vpngw
install -d -o root -g root -m 0700 /dev/shm/vpn_stats
if [[ -n "${TG_TOKEN:-}" ]]; then
  install -o root -g vpngw-bot -m 0640 /dev/null /etc/vpngw-bot.env
  cat > /etc/vpngw-bot.env <<EOF
TG_TOKEN="${TG_TOKEN}"
TG_ALLOWED_CHAT_IDS="${TG_ALLOWED_CHAT_IDS:-123456789}"
VPNGW_CONFIG="/etc/vpngw-bot.conf"
VPNGW_FUNCTIONS="/usr/local/bin/vpngw/vpn-functions.sh"
VPNGW_SPEED_CONFIG="/etc/vpngw-speed-tests.conf"
VPNGW_SWITCH_BIN="/usr/local/sbin/vpngw-root-switch"
VPNGW_STATE_DB="/var/lib/vpngw/bot_state.db"
VPNGW_QUEUE_DB="/var/lib/vpngw/bot_queue.db"
EOF
else
  chown root:vpngw-bot /etc/vpngw-bot.env
  chmod 0640 /etc/vpngw-bot.env
fi
if ! grep -q '^VPNGW_SPEED_CONFIG=' /etc/vpngw-bot.env; then
  printf '\nVPNGW_SPEED_CONFIG="/etc/vpngw-speed-tests.conf"\n' >> /etc/vpngw-bot.env
fi
chown root:vpngw-bot /etc/vpngw-bot.env
chmod 0640 /etc/vpngw-bot.env

install -o root -g root -m 0640 /dev/null /etc/vpngw-bot.conf
cat > /etc/vpngw-bot.conf <<'EOF'
# Safe bot config: read-only for bot user, no secrets.
MAIN_SH_DIR="/home/pi/app/vpngw"
VPN_IF="tun0"
ADG_BIN="/opt/adguardvpn_cli/adguardvpn-cli"
VPNGW_SWITCH_BIN="/usr/local/sbin/vpngw-root-switch"
SYSTEM_NAME="RPi4B"
STATS_DIR="/dev/shm/vpn_stats"
LOG_RAM="/dev/shm/vpn_stats/vpngw.log"
EOF
chown root:vpngw-bot /etc/vpngw-bot.conf
chmod 0640 /etc/vpngw-bot.conf
chmod 0640 /etc/vpngw-bot.env
install -d -o vpngw-bot -g vpngw-bot -m 0750 /var/lib/vpngw
for database in /var/lib/vpngw/bot_state.db /var/lib/vpngw/bot_queue.db; do
  if [[ -f "$database" ]]; then
    chown vpngw-bot:vpngw-bot "$database"
    chmod 0640 "$database"
  fi
done

install -o root -g root -m 0644 /home/pi/app/vpngw/python_bot/systemd/vpngw-bot.service /etc/systemd/system/vpngw-bot.service
systemctl daemon-reload
systemctl stop vpngw-bot.service 2>/dev/null || true
systemctl restart vpngw-bot.service
systemctl status vpngw-bot.service --no-pager -l --lines=25

printf '\n--- STATUS CHECK ---\n'
ps -eo pid,uid,comm,args --forest | grep -E 'vpngw_bot|python -m vpngw_bot|telegram' | grep -v grep || true
printf '\n--- SAFE FILES ---\n'
ls -l /etc/vpngw-bot.env /etc/vpngw-bot.conf
ls -l /etc/vpngw-speed-tests.conf
