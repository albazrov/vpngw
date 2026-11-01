#!/bin/bash

# version 20260528_01

# RPi4B
# vpn-loc-update.sh


# --- ПОДКЛЮЧЕНИЕ ПЕРЕМЕННЫХ И ДОПОЛНИТЕЛЬНЫЕ ФУНКЦИИ ---
CONF_FILE="/etc/vpn-gw.conf"

if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
else
    echo "[ERROR] Config file $CONF_FILE not found!" >&2
    exit 1
fi


log_msg() { echo "$(date '+%Y-%m-%d %H:%M:%S') - [LOC-UPDATE] $1" >> "$LOG_RAM"; }

log_msg "Starting scheduled locations update..."
# Получаем список, чистим от мусора
RAW_DATA=$(timeout 60s /opt/adguardvpn_cli/adguardvpn-cli list-locations | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')

if [ -n "$RAW_DATA" ] && echo "$RAW_DATA" | grep -q "ISO"; then
    echo "$RAW_DATA" > "$LOC_CACHE_DISK"
    cp "$LOC_CACHE_DISK" "$CACHE_FILE"
    log_msg "Success. Cache updated on DISK and RAM."
else
    log_msg "ERROR: Could not fetch locations from CLI."
    exit 1
fi

