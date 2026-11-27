#!/bin/bash
 
# version 20260528_01

# RPi4B 
# vpn-tg-send.sh

# Подключаем конфиг для получения токена и ID
# 1. Подключаем основной конфигурационный файл
CONF_FILE="/etc/vpn-gw.conf"

if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
else
    echo "Ошибка: Конфигурационный файл $CONF_FILE не найден!" >&2
    exit 1
fi

export -n TG_TOKEN 2>/dev/null || true

# 2. Динамически подключаем библиотеку функций, используя переменную пути из конфига
FUNCTIONS_LIB="$MAIN_SH_DIR/vpn-functions.sh"
if [ -f "$FUNCTIONS_LIB" ]; then
    # shellcheck disable=SC1090
    source "$FUNCTIONS_LIB"
else
    echo "Ошибка: Библиотека функций $FUNCTIONS_LIB не найдена!" >&2
    exit 1
fi

MESSAGE="$1"
umask 077
install -d -o root -g root -m 0700 -- "$QUEUE_DIR"

# 1. Если передано сообщение — сохраняем его в новый уникальный файл
if [ -n "$MESSAGE" ]; then
    # Имя файла — метка времени в наносекундах для уникальности
    echo "$MESSAGE" > "$QUEUE_DIR/msg_$(date +%s%N).tmp"
fi

# 2. Перебираем файлы по timestamp в имени; отсутствующие matches дают пустой список
shopt -s nullglob
msg_files=("$QUEUE_DIR"/*.tmp)
(( ${#msg_files[@]} > 0 )) || exit 0

for msg_file in "${msg_files[@]}"; do
    REQUEST_FILE=$(mktemp "$QUEUE_DIR/.request.XXXXXX")
    jq -Rs --arg chat_id "$TG_CHAT_ID" --arg mode "Markdown" \
        '{chat_id: $chat_id, text: ., parse_mode: $mode}' < "$msg_file" > "$REQUEST_FILE"

    http_code=$(telegram_api_curl sendMessage -s -4 -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        -H "Content-Type: application/json" \
        -X POST --data-binary "@$REQUEST_FILE")
    rm -f "$REQUEST_FILE"

    if [ "$http_code" == "200" ]; then
        # Успешно отправлено — удаляем файл сообщения
        rm -f "$msg_file"
    else
        # Ошибка связи (ISP блок) — прекращаем цикл до следующего раза
        log_message "[SKIP TG] Notification failed (HTTP $http_code)" "TG-SEND"
        exit 1
    fi
done


