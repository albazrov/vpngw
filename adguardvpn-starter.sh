#!/bin/bash

# version 20260528_01

# RPi4B
# adguardvpn-starter.sh

# --- ПОДКЛЮЧЕНИЕ КОНФИГУРАЦИИ ---
CONF_FILE="/etc/vpn-gw.conf"

if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
else
    echo "[ERROR] Config file $CONF_FILE not found!" >&2
    exit 1
fi

# Динамически подключаем библиотеку функций, используя переменную пути из конфига
FUNCTIONS_LIB="$MAIN_SH_DIR/vpn-functions.sh"
if [ -f "$FUNCTIONS_LIB" ]; then
    # shellcheck disable=SC1090
    source "$FUNCTIONS_LIB"
else
    echo "Ошибка: Библиотека функций $FUNCTIONS_LIB не найдена!" >&2
    exit 1
fi

# Локальные технические настройки
DEBUG=true
LOCK_FILE="/dev/shm/adguardvpn-starter.lock"
TIMEOUT_CMD="timeout 40s"

# --- ВНУТРЕННИЕ ФУНКЦИИ ---

# функция log_message определена в "/etc/vpn-gw.conf"
debug_log() { $DEBUG && log_message "DEBUG: $1" "STARTER"; }

# --- БЛОКИРОВКА ---
exec 8>"$LOCK_FILE"
if ! flock -n 8; then
    debug_log "Process already running. Lock file active."
    exit 0
fi

# --- ОТПРАВКА СООБЩЕНИЙ  ---
send_alert() {
    local mode="$1"    # Режим: "CRITICAL" (падение) или "OK" (восстановление)
    local message="$2" # Текст сообщения для Telegram (с Markdown-звездочками)
    local detail="$3"  # Дополнительный текст для Email (опционально, например, статистика перебора)

    # 1. Добавляем имя системы ко всем сообщениям
    local tg_msg=""
    local em_subj=""
    local em_body=""

    if [ "$mode" == "CRITICAL" ]; then
        tg_msg="⚠️ *[$SYSTEM_NAME]* $message"
        em_subj="[ CRITICAL ] Сбой системы на $SYSTEM_NAME"
        em_body="Внимание! На шлюзе $SYSTEM_NAME зафиксировано критическое событие.\n\nОписание: $(echo "$message" | tr -d '*')\nДата/Время: $(date '+%d.%m.%Y %H:%M:%S')"
    elif [ "$mode" == "OK" ]; then
        tg_msg="✅ *[$SYSTEM_NAME]* $message"
        em_subj="[ OK ] Система восстановлена на $SYSTEM_NAME"
        # Если $detail не пустой, добавляем его с переносом строки, иначе шлем только message
        if [ -n "$detail" ]; then
            em_body="Уведомление о возобновлении штатной работы шлюза $SYSTEM_NAME.\n\n$(echo "$message" | tr -d '*')\n\n$detail"
        else
            em_body="Уведомление о возобновлении штатной работы шлюза $SYSTEM_NAME.\n\n$(echo "$message" | tr -d '*')"
        fi

    else
        tg_msg="ℹ️ *[$SYSTEM_NAME]* $message"
        em_subj="[ INFO ] Уведомление от $SYSTEM_NAME"
        em_body="Системное сообщение от $SYSTEM_NAME:\n\n$(echo "$message" | tr -d '*')"
    fi

    # 2. Отправка в Telegram через существующую очередь
    send_tg "$tg_msg"

    # 3. Отправка на Email (вычищаем Markdown-звездочки из тела письма для красоты)
    local clean_em_body
    clean_em_body=$(echo -e "$em_body" | tr -d '*')
    "$MAIN_SH_DIR/vpn-email-send.sh" "$em_subj" "$clean_em_body"
}


# --- ФУНКЦИИ ПРОВЕРКИ ---
check_geo() {
    local geo_raw g_status g_country g_ip
    geo_raw=$(timeout 15s curl -sL --interface "$VPN_IF" "http://ip-api.com/line/?fields=status,countryCode,query" | tr -d '\r')
    g_status=$(echo "$geo_raw" | sed -n '1p')
    g_country=$(echo "$geo_raw" | sed -n '2p' | tr '[:lower:]' '[:upper:]')
    g_ip=$(echo "$geo_raw" | sed -n '3p')

    if [ "$g_status" = "success" ] && [ -n "$g_country" ]; then
        debug_log "External IP: [$g_ip], Geo: [$g_country]"
        echo "$g_country"
        return 0
    fi
    return 1
}

check_internet() {
    debug_log "Starting connectivity check..."
    
    # 1. Проверка физического интернета (ISP)
    local inet_ok=0
    local primary_target=${CHECK_TARGETS:-8.8.8.8}
    
    if ping -c 1 -W 2 -I "$NET_IF" "$primary_target" >/dev/null 2>&1; then 
        inet_ok=1
    fi
    
    check_state_change "inet" "$inet_ok" "Связь восстановлена" "Интернет пропал на $NET_IF!"

    # Если ISP лежит, выходим немедленно с кодом ошибки
    if [ "$inet_ok" -eq 0 ]; then
        debug_log "ISP is DOWN. Skipping VPN check to save time."
        return 1
    fi

    # 2. Проверка туннеля VPN (только если ISP в порядке)
    local vpn_ok=0
    if [ ! -d /sys/class/net/"$VPN_IF" ]; then
        debug_log "VPN check: Interface $VPN_IF is MISSING"
    else
        for target in "${CHECK_TARGETS[@]}"; do
            debug_log "Testing VPN via $target..."
            if timeout 5s curl -sI --interface "$VPN_IF" "https://$target" > /dev/null 2>&1; then
                vpn_ok=1
                debug_log "${CLR_GRN}VPN check SUCCESS ${CLR_RST}via $target"
                break
            fi
        done
    fi
    
    check_state_change "vpn" "$vpn_ok" "" "⚠️ Туннель VPN упал!"

    [ "$vpn_ok" -eq 1 ] && return 0 || return 1
}

# Функция сборки очереди
build_queue() {
    local mode="$1"

    # 1. Сначала всегда приоритеты из конфига
    local QUEUE
    QUEUE=$(printf "%s\n" "${PRIORITY_LOCS[@]}" | tr ' ' '\n' | awk '!seen[$0]++' | xargs)
    
    # 2. Если нужны дополнительные локации (расширенный поиск)
    if [ "$mode" == "full" ]; then
        # Ищем кэш: сначала RAM, потом DISK
        local SRC=""
        [ -s "$CACHE_FILE" ] && SRC="$CACHE_FILE" || SRC="$LOC_CACHE_DISK"
        
        if [ -s "$SRC" ]; then
            local ALL_ISO
            ALL_ISO=$(tail -n +2 "$SRC" | awk '{print $1}' | grep -xE '[A-Z]{2}' | awk '!seen[$0]++')
            for ISO in $ALL_ISO; do
                # Проверка на исключения и дубли в PRIORITY_LOCS
                [[ " ${PRIORITY_LOCS[*]} " == *" ${ISO} "* ]] && continue
                [[ " ${EXCLUDE_LOCS[*]} " == *" ${ISO} "* ]] && continue
                QUEUE+="$ISO "
            done
        fi
    fi
    echo "$QUEUE"
}

try_connect_queue() {
    local queue="$1"
    local start_time="$2" # Время начала сбоя, переданное из основного тела
    local attempt_info=0

    # Если висит флаг авторизации, сокращаем очередь до 1-й приоритетной локации
    if [ -f "$AUTH_FLAG" ]; then
        debug_log "Auth pending. Skipping connect, calling helper..."
        "$MAIN_SH_DIR/vpn-auth-helper.sh" 8>&-
        local auth_status=$?
        
        if [ $auth_status -eq 0 ]; then
             log_msg "Auth just restored! Proceeding to connect..."
             # Здесь продолжаем выполнение к циклу ниже
        else
             # Если все еще ждем (2) или ошибка (1) — выходим из всего стартера
             exit 0 
        fi
    fi

    # Восстанавливаем счетчик попыток из RAM, если это повторный запуск (после обновления кэша)
    [ -f "/dev/shm/vpn_stats/current_try_count" ] && attempt_info=$(cat /dev/shm/vpn_stats/current_try_count)

    for LOC in $queue; do
        ((attempt_info++))
        echo "$attempt_info" > /dev/shm/vpn_stats/current_try_count
        
        debug_log "Mode: RECOVERY. Connecting to $LOC (Attempt: $attempt_info)..."
                
        # 2. Выполняем подключение и сохраняем ответ для анализа
        local conn_res
        conn_res=$($TIMEOUT_CMD /opt/adguardvpn_cli/adguardvpn-cli connect -l "$LOC" 2>&1 8>&-)
        
        # 3. Проверка необходимости авторизации (вызов внешнего хелпера)
        if echo "$conn_res" | grep -qiE "log in|authorize|account|limit"; then
            debug_log "CRITICAL: Auth/Account error detected!"
            
            # Вызываем хелпер авторизации
            "$MAIN_SH_DIR/vpn-auth-helper.sh" 8>&-
            local auth_status=$?
            
            if [ $auth_status -eq 0 ]; then
                log_msg "Auth just restored! Retrying connect to $LOC..."
                # Повторяем коннект, так как теперь мы авторизованы
                /opt/adguardvpn_cli/adguardvpn-cli connect -l "$LOC" > /dev/null 2>&1 8>&-
                sleep 20
                if check_internet; then
                    # Если успех - формируем отчет и выходим (как при обычном успехе)
                    ACTUAL_ISO=$(check_geo)
                    inc_stat "cnt_success"
                    debug_log "System is ${CLR_GRN}healthy${CLR_RST}. ISO: [$ACTUAL_ISO]"
                    return 0
                fi
            elif [ $auth_status -eq 2 ]; then
                # Режим ожидания ссылки или подтверждения в браузере
                # Скрипт просто завершается, крон попробует снова позже
                exit 0 
            else
                # Критическая ошибка (например, не удалось отправить Email)
                send_alert "CRITICAL" "AdGuard VPN: Сбой авторизации и хелпера."
                exit 1
            fi
        fi

        # 4. Если команда connect принята, ждем поднятия туннеля
        debug_log "Wait for tunnel after connect to $LOC..."
        sleep 20
        
        # 5. Проверка результата
        if check_internet; then
            local end_time
            end_time=$(date '+%H:%M:%S')
            debug_log "SUCCESS: Connected to $LOC."
            inc_stat "cnt_recon"
            
            # Формируем короткое сообщение (основные детали функция em_body сгенерирует сама ниже)
            local tg_report
            tg_report="VPN восстановлен!
📍 Локация: *$LOC*
⏰ Сбой обнаружен: *$start_time*
🏁 Восстановлено: *$end_time*
🔄 Попыток перебора: *$attempt_info*"

            # Передаем в качестве $detail пустую строку, так как вся статистика уже есть в tg_report
            send_alert "OK" "$tg_report" ""

            "$MAIN_SH_DIR/vpn-bypass-update.sh" 8>&-
            return 0
        fi

    done
    # Если прошли весь список и не подключились
    return 1
}

# --- ОСНОВНАЯ ЛОГИКА ---

if ! ensure_stats_dir; then
    printf 'Unsafe or missing stats directory: %s (expected root:root 0700)\n' "$STATS_DIR" >&2
    exit 1
fi
inc_stat "cnt_checks"
check_temp_health

# 0. Если мы в режиме ожидания авторизации — не проверяем интернет, сразу к хелперу
if [ -f "$AUTH_FLAG" ]; then
    debug_log "System in AUTH_WAIT mode. Checking helper..."
    if ! "$MAIN_SH_DIR/vpn-auth-helper.sh" 8>&-; then
        exit 0
    fi
fi

# ПЕРВАЯ И ГЛАВНАЯ ПРОВЕРКА
if check_internet; then
    # Если мы здесь, значит интернет и VPN работают. 
    # Проверяем, не висит ли флаг ожидания авторизации
    if [ -f "$AUTH_FLAG" ]; then 
        # Вызываем хелпер — он увидит статус 'connected', удалит флаг, 
        # убьет фоновый процесс login и очистит adguard_auth.tmp 
        "$MAIN_SH_DIR/vpn-auth-helper.sh" 8>&- 
    fi

    ACTUAL_ISO=$(check_geo)
    if [ "$CHECK_PRIORITY" = false ]; then
        inc_stat "cnt_success"
        debug_log "System is ${CLR_GRN}healthy${CLR_RST}. ISO: [$ACTUAL_ISO]"
        exit 0
    fi
fi
# ... после того как check_internet вернул 1 ...
# Проверяем физический линк (ISP)
if ! ping -c 1 -W 2 -I "$NET_IF" "${CHECK_TARGETS[0]}" >/dev/null 2>&1; then
    log_message "${CLR_RED}Physical link ($NET_IF) is DOWN.${CLR_RST} Waiting for restoration..." "STARTER"
    
    wait_count=0
    max_wait=10 # Максимум 10 итераций
    
    while ! ping -c 1 -W 2 -I "$NET_IF" "${CHECK_TARGETS[0]}" >/dev/null 2>&1; do
        ((wait_count++))
        debug_log "${CLR_RED}ISP still DOWN.${CLR_RST} Attempt $wait_count/$max_wait. Sleeping 20s..."
        
        if [ "$wait_count" -ge "$max_wait" ]; then
            log_message "ISP wait timeout reached ($((max_wait * 20))s). ${CLR_RED}Exiting to retry by cron.${CLR_RST}" "STARTER"
            # Удаляем временные файлы, если нужно, и выходим
            exit 1 
        fi
        
        sleep 20
    done
    log_message "${CLR_GRN}Physical link is RESTORED${CLR_RST} after $((wait_count * 20))s. Proceeding to VPN recovery." "STARTER"
fi
# Как только интернет на eth0 появился, начинаем стандартный RECOVERY
# --- Перед началом восстановления ---

# Фиксируем время, когда мы официально признали "падение"
RECOVERY_START_TIME=$(date '+%H:%M:%S')
inc_stat "cnt_failures" 
debug_log "${CLR_YLW}Action required. Starting RECOVERY logic${CLR_RST} at $RECOVERY_START_TIME..."

# Пытаемся восстановиться: сначала Приоритеты, затем Кэш
# Собираем общую очередь (build_queue "full" уже включает в себя приоритеты в начале)
FINAL_QUEUE=$(build_queue "full")

# Передаем время старта в функцию вторым аргументом (вместо mode_name)
if try_connect_queue "$FINAL_QUEUE" "$RECOVERY_START_TIME"; then
    exit 0
fi

debug_log "${CLR_RED}Recovery failed.${CLR_RST} Updating cache from CLI..."

# Если ничего не помогло — обновляем кэш и пробуем последний раз
if "$MAIN_SH_DIR/vpn-loc-update.sh" 8>&- ; then
    RETRY_QUEUE=$(build_queue "full")
    if try_connect_queue "$RETRY_QUEUE" "$RECOVERY_START_TIME"; then
        exit 0
    fi
fi

debug_log "${CLR_RED}CRITICAL: All attempts failed.${CLR_RST}"
exit 1

