#!/bin/bash
 
# version 20260528_01

# RPi4B 
# vpn-tg-send.sh

# Подключаем конфиг для получения токена и ID
# 1. Подключаем основной конфигурационный файл
CONF_FILE="/etc/vpn-gw.conf"

if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    echo "Ошибка: Конфигурационный файл $CONF_FILE не найден!" >&2
    exit 1
fi

# 2. Динамически подключаем библиотеку функций, используя переменную пути из конфига
FUNCTIONS_LIB="$MAIN_SH_DIR/vpn-functions.sh"
if [ -f "$FUNCTIONS_LIB" ]; then
    source "$FUNCTIONS_LIB"
else
    echo "Ошибка: Библиотека функций $FUNCTIONS_LIB не найдена!" >&2
    exit 1
fi

MESSAGE="$1"
#QUEUE_DIR="/dev/shm/tg_queue"
mkdir -p "$QUEUE_DIR"

# 1. Если передано сообщение — сохраняем его в новый уникальный файл
if [ -n "$MESSAGE" ]; then
    # Имя файла — метка времени в наносекундах для уникальности
    echo "$MESSAGE" > "$QUEUE_DIR/msg_$(date +%s%N).tmp"
fi

# 2. Если папка пуста — выходим
[ "$(ls -A $QUEUE_DIR)" ] || exit 0

# 3. Перебираем файлы в папке по порядку создания
for msg_file in $(ls -tr "$QUEUE_DIR"/*.tmp 2>/dev/null); do
    # Читаем весь файл целиком в переменную
    FINAL_MSG=$(cat "$msg_file")

    http_code=$(curl -s -4 -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        -H "Content-Type: application/json" \
        -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        -d "$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$FINAL_MSG" --arg mode "Markdown" \
            '{chat_id: $chat_id, text: $text, parse_mode: $mode}')")

    if [ "$http_code" == "200" ]; then
        # Успешно отправлено — удаляем файл сообщения
        rm -f "$msg_file"
    else
        # Ошибка связи (ISP блок) — прекращаем цикл до следующего раза
        log_message "[SKIP TG] Notification failed (HTTP $http_code)" "TG-SEND"
        exit 1
    fi
done


