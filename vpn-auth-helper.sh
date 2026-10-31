#!/bin/bash

# version 20260528_01

# RPi4B
# vpn-auth-helper.sh

# --- ПОДКЛЮЧЕНИЕ ПЕРЕМЕННЫХ И ДОПОЛНИТЕЛЬНЫЕ ФУНКЦИИ ---
CONF_FILE="/etc/vpn-gw.conf"

if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    echo "[ERROR] Config file $CONF_FILE not found!" >&2
    exit 1
fi

# Динамически подключаем библиотеку функций, используя переменную пути из конфига
FUNCTIONS_LIB="$MAIN_SH_DIR/vpn-functions.sh"
if [ -f "$FUNCTIONS_LIB" ]; then
    source "$FUNCTIONS_LIB"
else
    echo "Ошибка: Библиотека функций $FUNCTIONS_LIB не найдена!" >&2
    exit 1
fi
# ___ ___ ___ ___ ___ ___ ___ ___ ___ ___ ___ ___ ___ ___

if ! ensure_stats_dir; then
    printf 'Unsafe or missing stats directory: %s (expected root:root 0700)\n' "$STATS_DIR" >&2
    exit 1
fi

log_msg() { log_message "$1" "AUTH-HELPER"; }

# Внутренняя функция для отправки с проверкой результата
safe_send_email() {
    local url="$1"
    local msg_type="$2"
    
    # Формируем тему для аларма авторизации
    local alert_subject="[ ALERT ] Требуется авторизация для $SYSTEM_NAME"
    local alert_body="Для возобновления работы VPN на шлюзе $SYSTEM_NAME требуется ручное подтверждение в браузере:\n\n$url\n\nСсылка активна 30 минут."
    
    log_msg "$msg_type link captured. Sending Email..."
    
    # Передаем и тему, и тело сообщения
    "$MAIN_SH_DIR/vpn-email-send.sh" "$alert_subject" "$alert_body"
    
    if [ $? -eq 0 ]; then
        echo "$url" > "$LAST_URL_FILE"
        log_msg "Email sent successfully. Link saved to history."
        return 0
    else
        log_msg "ERROR: Email delivery failed. Will retry next time."
        #log_msg "ERROR: current url=$url"
        #log_msg "ERROR: last url=$last_net_url"
        return 1
    fi
}

# --- 1. ПРОВЕРКА УСПЕХА (Только если флага нет) ---
if [ ! -f "$AUTH_FLAG" ]; then
    if /opt/adguardvpn_cli/adguardvpn-cli status | grep -qiE "disconnected|connected"; then
        exit 0
    fi
fi

# --- 2. МОНИТОРИНГ ТЕКУЩЕЙ СЕССИИ (если флаг существует) ---
if [ -f "$AUTH_FLAG" ]; then
    # Проверяем "техническое здоровье" сессии
    session_healthy=true
    
    # А) Проверка размера
    local file_size=$(du -k "$AUTH_TMP" 2>/dev/null | cut -f1 || echo 0)
    [ "$file_size" -gt 1024 ] && session_healthy=false && log_msg "WARN: Log too large."
    
    # Б) Проверка времени (25 минут)
    if [ "$session_healthy" = true ]; then
        ELAPSED=$(( $(date +%s) - $(stat -c %Y "$AUTH_FLAG") ))
        [ "$ELAPSED" -gt "$URL_TIME_VALID" ] && session_healthy=false && log_msg "WARN: Link expired."
    fi
    log_msg "Проверка времени: ELAPSED=$ELAPSED"

    # В) Проверка наличия процесса
    if [ "$session_healthy" = true ]; then
        pgrep -f "adguardvpn-cli login" > /dev/null || { session_healthy=false; log_msg "WARN: Process missing."; }
    fi

    if [ "$session_healthy" = true ]; then # Если session_healthy = false то не входя в цикл сразу на шаг 3 где очистка и создание новой сессии login
        # --- ЦИКЛ БЫСТРОГО ОПРОСА ---
        for ((i=1; i<=AUTH_POLL_COUNT; i++)); do
            # Проверка на успех
            if grep -qi "Successfully Logged in" "$AUTH_TMP" 2>/dev/null; then
                log_msg "Auth success detected in PTY log!"
                if /opt/adguardvpn_cli/adguardvpn-cli status | grep -qiE "disconnected|connected"; then
                    log_msg "${CLR_GRN}[CLEANUP]${CLR_RST} Auth confirmed. Cleaning files."
                    pkill -f "adguardvpn-cli login" 2>/dev/null
                    rm -f "$AUTH_FLAG" "$AUTH_TMP" "$LAST_URL_FILE"
                    send_tg "🔑 *[$SYSTEM_NAME]* Авторизация восстановлена!"
                    exit 0
                fi
            fi
            
            # Проверка на "мусор" (если файл не пуст, но нет ни ссылки, ни успеха)
            if [ -s "$AUTH_TMP" ] && ! grep -qiE "Successfully|https://" "$AUTH_TMP"; then
                log_msg "WARN: Log corrupted (trash detected). Recycling..."
                session_healthy=false
                break
            fi

            # Проверка ссылки
            current_log_url=$(sed -r "s/\x1B\[(([0-9]+(;[0-9]+)*)?[mK,H,J,f])//g" "$AUTH_TMP" | grep -oP 'https://\S+device_code\?\S+' | tail -n 1)
            last_sent_url=$(cat "$LAST_URL_FILE" 2>/dev/null)
            if [ -n "$current_log_url" ]; then
                if [ "$current_log_url" != "$last_sent_url" ] || [ ! -f "$LAST_URL_FILE" ]; then
                    if ! safe_send_email "$current_log_url" "Link delivery"; then
                        log_msg "CRITICAL: Email failed. Exiting to retry by cron."
                        exit 2 
                    fi
                fi
            fi
            #log_msg "i=$i"
            #log_msg "Проверка ссылки: for $i: current_log_url=$current_log_url"
            #log_msg "Проверка ссылки: for $i: last_sent_url=$last_sent_url"

            #log_msg "DEBUG: File size: $(stat -c %s "$AUTH_TMP") bytes"
            # Вывод первых 50 символов строки с ссылкой (если она видна sed-у)
            #log_msg "DEBUG: Raw line: $(grep "https" "$AUTH_TMP" | tail -n 2)"


            [ $i -lt "$AUTH_POLL_COUNT" ] && sleep "$AUTH_POLL_INTERVAL"
        done
        
        # Если цикл прошел и всё еще ждем (без сбоев)
        [ "$session_healthy" = true ] && { log_msg "Still waiting...(ELAPSED $ELAPSED)"; exit 2; }
    fi
fi

# --- 3. ИНИЦИАЛИЗАЦИЯ (Сюда попадаем, если флага не было ИЛИ сессия признана нездоровой) ---
log_msg "Starting fresh detached auth session..."
pkill -f "adguardvpn-cli login" 2>/dev/null
rm -f "$AUTH_FLAG" "$AUTH_TMP" "$LAST_URL_FILE" # Полная чистка перед стартом
touch "$AUTH_FLAG"

sudo nohup setsid /usr/bin/script -q -c "/opt/adguardvpn_cli/adguardvpn-cli login" /dev/null > "$AUTH_TMP" 2>&1 &

sleep 10
AUTH_URL=$(grep -oP 'https://\S+device_code\?\S+' "$AUTH_TMP" | tail -n 1)
if [ -n "$AUTH_URL" ]; then
    safe_send_email "$AUTH_URL" "Initial"
    exit 2
else
    log_msg "ERROR: Capture failed. Clean flag for cron retry."
    rm -f "$AUTH_FLAG"
    exit 1
fi
