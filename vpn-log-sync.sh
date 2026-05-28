#!/bin/bash

# version 20260528_01

# RPi4B
# vpn-log-sync.sh

# --- ПОДКЛЮЧЕНИЕ ПЕРЕМЕННЫХ И ДОПОЛНИТЕЛЬНЫЕ ФУНКЦИИ ---
CONF_FILE="/etc/vpn-gw.conf"

if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    echo "[ERROR] Config file $CONF_FILE not found!" >&2
    exit 1
fi


if [ -s "$LOG_RAM" ]; then
    cat "$LOG_RAM" >> "$LOG_DISK"
    > "$LOG_RAM"
    # Ротация архивного лога (2МБ)
    if [ $(stat -c%s "$LOG_DISK") -gt 2097152 ]; then
        mv "$LOG_DISK" "${LOG_DISK}.1"
        touch "$LOG_DISK"
    fi
fi

