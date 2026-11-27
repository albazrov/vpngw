#!/bin/bash

# version 20260528_01

# RPi4B
# vpn-log-sync.sh

# --- ПОДКЛЮЧЕНИЕ ПЕРЕМЕННЫХ И ДОПОЛНИТЕЛЬНЫЕ ФУНКЦИИ ---
CONF_FILE="/etc/vpn-gw.conf"

if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
else
    echo "[ERROR] Config file $CONF_FILE not found!" >&2
    exit 1
fi

FUNCTIONS_LIB="${VPNGW_FUNCTIONS:-$MAIN_SH_DIR/vpn-functions.sh}"
if [ -f "$FUNCTIONS_LIB" ]; then
    # shellcheck disable=SC1090
    source "$FUNCTIONS_LIB"
else
    echo "Ошибка: Библиотека функций $FUNCTIONS_LIB не найдена!" >&2
    exit 1
fi

flush_vpn_log

