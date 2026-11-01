#!/bin/bash

# version 20260528_01
# RPi4B
# vpn-email-send.sh

# --- ПОДКЛЮЧЕНИЕ КОНФИГУРАЦИИ ---
CONF_FILE="/etc/vpn-gw.conf"

if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
else
    echo "[ERROR] Config file $CONF_FILE not found!" >&2
    exit 1
fi

# Перехватываем два параметра: первый — ТЕМА, второй — СООБЩЕНИЕ
RAW_SUBJECT="$1"
MESSAGE="$2"

TO="al.bazrov@yandex.ru, tunmonitor@gmail.com"
FROM="al.bazrov@yandex.ru"
MSMTP_CONF="/etc/msmtprc"
MSMTP_ACC="default"

# Если тема или сообщение пустые — выходим
if [ -z "$RAW_SUBJECT" ] || [ -z "$MESSAGE" ]; then exit 0; fi

# Задаем дефолтное имя отправителя, если переменной нет в конфиге
[ -z "$FROMTEXT" ] && FROMTEXT="Monitoring $SYSTEM_NAME"

# Шифруем динамическую тему в Base64 для защиты кириллицы на серверах Яндекса
ENCODED_SUBJECT=$(echo -n "$RAW_SUBJECT" | base64 | tr -d '\n')
SUBJECT="=?UTF-8?B?${ENCODED_SUBJECT}?="

# Отправка через msmtp по проверенной и рабочей схеме
if echo -e "From: $FROMTEXT <$FROM>\nTo: $TO\nSubject: $SUBJECT\n\n$MESSAGE" | msmtp -C "$MSMTP_CONF" -a "$MSMTP_ACC" al.bazrov@yandex.ru tunmonitor@gmail.com; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [EMAIL-SEND] Success sent to mail boxes" >> "$LOG_RAM"
    exit 0
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [EMAIL-SEND] ERROR: Failed to send email." >> "$LOG_RAM"
    exit 1
fi
