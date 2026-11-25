#!/bin/bash

# version 20260527_01

# RPi4B 
# vpn-tg-bot.sh


# 1. Подключаем основной конфигурационный файл
CONF_FILE="/etc/vpn-gw.conf"
if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    echo "Ошибка: Конфигурационный файл $CONF_FILE не найден!" >&2
    exit 1
fi

export -n TG_TOKEN 2>/dev/null || true

# 2. Динамически подключаем библиотеку функций, используя переменную пути из конфига
FUNCTIONS_LIB="$MAIN_SH_DIR/vpn-functions.sh"
if [ -f "$FUNCTIONS_LIB" ]; then
    source "$FUNCTIONS_LIB"
else
    echo "Ошибка: Библиотека функций $FUNCTIONS_LIB не найдена!" >&2
    exit 1
fi

if ! ensure_stats_dir; then
    printf 'Unsafe or missing stats directory: %s (expected root:root 0700)\n' "$STATS_DIR" >&2
    exit 1
fi

[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE") || OFFSET=0

log_msg() { log_message "$1" "TG-BOT"; }

# Функция отправки меню с Inline-кнопками (использует прямой curl, так как требует reply_markup)
send_bot_menu() {
    local chat_id="$1"
    local keyboard=$(jq -n '{
        inline_keyboard: [
            [
                { text: "🇷🇴 Румыния (RO)", callback_data: "/set_RO" },
                { text: "🇩🇪 Германия (DE)", callback_data: "/set_DE" }
            ],
            [
                { text: "🇫🇮 Финляндия (FI)", callback_data: "/set_FI" },
                { text: "📊 Текущий Статус", callback_data: "/status" }
            ]
        ]
    }')
    
    # Лучший вариант: с таймаутами, проверкой HTTP-кода и поддержкой кнопок
    local http_code=$(telegram_api_curl sendMessage -s -4 -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$(jq -n --arg chat "$chat_id" --arg text "📍 Выберите локацию для переключения AdGuard VPN шлюза:" --argjson kb "$keyboard" \
            '{chat_id: $chat, text: $text, reply_markup: $kb}')")

    if [ "$http_code" != "200" ]; then
        log_msg "ERROR: Failed to send bot menu (HTTP $http_code)"
    fi
}


log_msg "Telegram Control Bot daemon started."

while true; do
    UPDATES=$(telegram_api_curl getUpdates -s -4 --connect-timeout 35 --max-time 40 \
        --get --data-urlencode "offset=$OFFSET" --data-urlencode "timeout=30")
    
    # Оптимальный и быстрый вариант проверки:
    if [ -z "$UPDATES" ]; then sleep 5; continue; fi

    # Если в ответе пришел штатный пустой массив (результат Long Polling без новых сообщений)
    if [[ "$UPDATES" == *'"result":[]'* ]]; then continue; fi

    # И только если там есть данные, проверяем статус .ok через jq
    if [ "$(echo "$UPDATES" | jq -r '.ok')" != "true" ]; then sleep 5; continue; fi



    COUNT=$(echo "$UPDATES" | jq '.result | length')
    [ "$COUNT" -eq 0 ] && continue

    for ((i=0; i<COUNT; i++)); do
        UPDATE=$(echo "$UPDATES" | jq ".result[$i]")
        UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
        
        OFFSET=$((UPDATE_ID + 1))
        echo "$OFFSET" > "$OFFSET_FILE"

        TEXT=$(echo "$UPDATE" | jq -r '.message.text // empty')
        CHAT_ID=$(echo "$UPDATE" | jq -r '.message.chat.id // empty')
        CALLBACK_ID=""

        if [ -z "$TEXT" ]; then
            TEXT=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
            CALLBACK_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')
            CHAT_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.chat.id // empty')
            
            # Быстрое подтверждение клика, чтобы в интерфейсе скрылись часики ожидания
            if [ -n "$CALLBACK_ID" ]; then
                telegram_api_curl answerCallbackQuery -s -4 --connect-timeout 3 --max-time 5 \
                    --get --data-urlencode "callback_query_id=$CALLBACK_ID" > /dev/null
            fi
        fi

        # ЗАЩИТА: бот реагирует только на ваш TG_CHAT_ID
        if [ "$CHAT_ID" != "$TG_CHAT_ID" ]; then
            log_msg "WARN: Unauthorized access from Chat ID: $CHAT_ID"
            continue
        fi

        case "$TEXT" in
            "/start"|"/menu")
                send_bot_menu "$CHAT_ID"
                ;;
                
            "/status")
                # 1. Сначала быстро отправляем заглушку, так как теперь у нас два сетевых запроса (Geo + Speed)
                send_tg "⏳ *[$SYSTEM_NAME]* Сбор данных и замер скорости, пожалуйста, подождите..."

                # 2. Получаем геолокацию через новую функцию из библиотеки
                # Передаем интерфейс как аргумент и проверяем результат работы функции
                if CLI_STATUS=$(check_geo "$VPN_IF"); then
                    # Если функция завершилась успешно, в CLI_STATUS уже лежит код страны (например, DE, NL)
                    LOCATION_DISPLAY="*$CLI_STATUS*"
                else
                    # Если функция вернула ошибку, значит трафика через интерфейс нет
                    LOCATION_DISPLAY="*DISCONNECTED*"
                fi
                
                # 3. Замеряем скорость передачи данных
                SPEED=$(get_vpn_download_speed "$VPN_IF")
                
                if [ "$?" -eq 0 ] && [ "${SPEED%.*}" -gt 0 ]; then
                    SPEED_DISPLAY="*$SPEED Мбит/с*"
                else
                    SPEED_DISPLAY="_Ошибка замера (Таймаут)_"
                fi

                # 4. Отправляем итоговое сообщение со всеми данными
                send_tg "📊 *[$SYSTEM_NAME] Текущий статус шлюза:*
📍 Активная локация: $LOCATION_DISPLAY
📥 Скорость скачивания: $SPEED_DISPLAY
🌡 Температура CPU: *$("$MAIN_SH_DIR/vpn-hw-check.sh")°C*
⏱ Аптайм: *$(uptime -p | sed 's/up //')*"
                ;;


            /set_*)
                LOC_ISO=${TEXT#/set_}
                log_msg "User requested switch to: $LOC_ISO"
                
                # Отправляем через вашу очередь
                send_tg "🔄 *[$SYSTEM_NAME]* Выполняю переключение на локацию *$LOC_ISO*..."
                
                if run_adguard_connect "$LOC_ISO"; then
                    :
                else
                    CLI_EXIT=$?
                    log_msg "ERROR: AdGuard CLI connect failed (exit $CLI_EXIT) for $LOC_ISO"
                    send_tg "❌ *[$SYSTEM_NAME]* Не удалось запустить подключение к *$LOC_ISO* (код $CLI_EXIT). Маршруты не изменены."
                    continue
                fi

                sleep 5
                
                # Перестраиваем таблицы маршрутизации
                "$MAIN_SH_DIR/vpn-bypass-update.sh" 8>&-
                
                # Проверяем успешность
                if check_vpn_connectivity "$VPN_IF"; then
                    send_tg "✅ *[$SYSTEM_NAME]* Успешно подключено к локации *$LOC_ISO*! Маршруты и база RU-IP обновлены."
                else
                    send_tg "❌ *[$SYSTEM_NAME]* Ошибка! Локация *$LOC_ISO* выбрана, но трафик через $VPN_IF не идет. Стартер попытается восстановить сеть."
                fi
                ;;
                
            *)
                [ -n "$TEXT" ] && send_bot_menu "$CHAT_ID"
                ;;
        esac
    done
done



