#!/bin/bash

# version 20260528_01

# RPi4B 
# vpn-functions.sh

# Используются переменные из vpn-gw.conf

# Библиотека общих функций для управления VPN

run_adguard_connect() {
    local location="${1:-}"

    if [ -z "$location" ]; then
        return 2
    fi

    if [ -z "${ADG_BIN:-}" ] || ! command -v "$ADG_BIN" >/dev/null 2>&1; then
        return 127
    fi

    if [ "$(id -u)" -ne 0 ] && [ -n "${VPNGW_SWITCH_BIN:-}" ]; then
        if ! command -v "$VPNGW_SWITCH_BIN" >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
            return 127
        fi
        sudo -n -- "$VPNGW_SWITCH_BIN" "$location"
        return $?
    fi

    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        sudo -n -- "$ADG_BIN" connect -l "$location" >/dev/null 2>&1
        return $?
    fi

    "$ADG_BIN" connect -l "$location" >/dev/null 2>&1
}

telegram_api_curl() {
    local endpoint="${1:-}"
    shift || return 2

    case "$endpoint" in
        getUpdates|sendMessage|answerCallbackQuery) ;;
        *) return 2 ;;
    esac

    if [[ ! "${TG_TOKEN:-}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        return 78
    fi

    export -n TG_TOKEN 2>/dev/null || true
    curl --config <(printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TG_TOKEN" "$endpoint") "$@"
}

ensure_private_directory() {
    local directory="${1:-}"
    local expected_owner="${2:-}"
    local expected_group="${3:-}"
    local expected_mode="${4:-}"
    local actual

    if [[ -z "$directory" || -z "$expected_owner" || -z "$expected_group" || -z "$expected_mode" ]]; then
        return 2
    fi
    if [[ ! -d "$directory" || -L "$directory" ]]; then
        return 1
    fi

    actual=$(stat -c '%u:%g:%a' -- "$directory") || return 1
    [[ "$actual" == "$expected_owner:$expected_group:$expected_mode" ]]
}

ensure_stats_dir() {
    if [[ "${STATS_DIR:-}" != "/dev/shm/vpn_stats" ]]; then
        return 2
    fi
    ensure_private_directory "$STATS_DIR" 0 0 700
}

check_vpn_connectivity() {
    # Функция принимает один аргумент — имя интерфейса
    local interface="$1"
    
    # Защита: если интерфейс не передан, сразу возвращаем ошибку
    if [ -z "$interface" ]; then
        echo "[ERROR] Интерфейс не указан в функции check_vpn_connectivity" >&2
        return 2
    fi

    # Проверяем, существует ли вообще массив CHECK_TARGETS
    if [ ${#CHECK_TARGETS[@]} -eq 0 ]; then
        echo "[WARNING] Список CHECK_TARGETS пуст или не задан. Используем хост по умолчанию." >&2
        local fallback_targets=("1.1.1.1" "8.8.8.8")
        local targets=("${fallback_targets[@]}")
    else
        local targets=("${CHECK_TARGETS[@]}")
    fi

    # Цикл проверки хостов
    for target in "${targets[@]}"; do
        if curl -s --interface "$interface" --connect-timeout 5 "$target" >/dev/null; then
            return 0 # Успех: хотя бы один хост ответил
        fi
    done
    
    return 1 # Ошибка: ни один хост из списка не доступен
}


# ПРОВЕРКА СКОРОСТИ КАНАЛА 

list_vpn_speed_tests() {
    local config_file="${VPNGW_SPEED_CONFIG:-$(dirname -- "${BASH_SOURCE[0]}")/vpn-speed-tests.conf}"
    local -a VPN_SPEED_TEST_IDS=()
    local -A VPN_SPEED_TEST_NAMES=()
    local -A VPN_SPEED_TEST_URLS=()
    local -A VPN_SPEED_TEST_CONNECT_TIMEOUT=()
    local -A VPN_SPEED_TEST_MAX_TIME=()

    if [ ! -r "$config_file" ]; then
        echo "Speed test config is not readable: $config_file" >&2
        return 1
    fi
    source "$config_file"

    local profile profile_url connect_timeout max_time
    for profile in "${VPN_SPEED_TEST_IDS[@]}"; do
        profile_url="${VPN_SPEED_TEST_URLS[$profile]:-}"
        connect_timeout="${VPN_SPEED_TEST_CONNECT_TIMEOUT[$profile]:-6}"
        max_time="${VPN_SPEED_TEST_MAX_TIME[$profile]:-20}"
        if [[ "$profile" =~ ^[a-zA-Z0-9_-]+$ ]] &&
            [ -n "${VPN_SPEED_TEST_NAMES[$profile]:-}" ] &&
            [[ "$profile_url" == https://* ]] &&
            [[ "$connect_timeout" =~ ^[1-9][0-9]?$ ]] &&
            [[ "$max_time" =~ ^[1-9][0-9]{0,2}$ ]] &&
            (( connect_timeout <= 60 && max_time <= 120 )); then
            printf '%s|%s\n' "$profile" "${VPN_SPEED_TEST_NAMES[$profile]}"
        fi
    done
}

get_vpn_download_speed() {
    local interface="$1"
    local profile="${2:-}"
    local override_url="${3:-}"
    local override_connect_timeout="${4:-}"
    local override_max_time="${5:-}"
    local resolve_host="${6:-}"
    local resolve_ip="${7:-}"
    
    # 1. Защита от пустого интерфейса
    if [ -z "$interface" ]; then
        echo "0"
        return 2
    fi

    local test_url connect_timeout max_time
    if [ -n "$override_url" ]; then
        test_url="$override_url"
        connect_timeout="$override_connect_timeout"
        max_time="$override_max_time"
    else
        local config_file="${VPNGW_SPEED_CONFIG:-$(dirname -- "${BASH_SOURCE[0]}")/vpn-speed-tests.conf}"
        local -a VPN_SPEED_TEST_IDS=()
        local -A VPN_SPEED_TEST_NAMES=()
        local -A VPN_SPEED_TEST_URLS=()
        local -A VPN_SPEED_TEST_CONNECT_TIMEOUT=()
        local -A VPN_SPEED_TEST_MAX_TIME=()

        if [ ! -r "$config_file" ]; then
            echo "0"
            return 1
        fi
        source "$config_file"

        if [ -z "$profile" ]; then
            profile="${VPN_SPEED_TEST_IDS[0]:-}"
        fi
        if [[ ! "$profile" =~ ^[a-zA-Z0-9_-]+$ ]] || [ -z "${VPN_SPEED_TEST_URLS[$profile]:-}" ]; then
            echo "0"
            return 1
        fi

        test_url="${VPN_SPEED_TEST_URLS[$profile]}"
        connect_timeout="${VPN_SPEED_TEST_CONNECT_TIMEOUT[$profile]:-6}"
        max_time="${VPN_SPEED_TEST_MAX_TIME[$profile]:-20}"
    fi
    if [[ "$test_url" != https://* ]] || [[ ! "$connect_timeout" =~ ^[1-9][0-9]?$ ]] ||
        [[ ! "$max_time" =~ ^[1-9][0-9]{0,2}$ ]] || (( connect_timeout > 60 || max_time > 120 )); then
        echo "0"
        return 1
    fi

    # 3. Делаем замер скорости через curl
    # -w "%{speed_download}" возвращает среднюю скорость в байтах в секунду
    # Таймауты и URL берутся из отдельного root-owned конфигурационного файла

    local -a curl_args=(-s -S -4 --proto '=https' --interface "$interface" --connect-timeout "$connect_timeout" --max-time "$max_time")
    if [ -n "$resolve_host" ] && [ -n "$resolve_ip" ]; then
        curl_args+=(--resolve "$resolve_host:443:$resolve_ip")
    fi
    local speed_result speed_bytes http_code curl_status
    speed_result=$(curl "${curl_args[@]}" "$test_url" -o /dev/null -w "%{speed_download}|%{http_code}")
    curl_status=$?
    speed_bytes="${speed_result%|*}"
    http_code="${speed_result##*|}"

    # Redirect/error responses are not valid download measurements.
    if [ "$curl_status" -ne 0 ] || [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]] ||
        [ -z "$speed_bytes" ] || [ "${speed_bytes%.*}" -eq 0 ]; then
        echo "0"
        return 1
    fi

    # 4. Переводим байты/сек в мегабиты/сек (Традиционный формат спидтестов)
    # Формула: (Байты * 8) / 1024 / 1024 = Мбит/с
    local speed_mbps
    speed_mbps=$(awk "BEGIN {print ($speed_bytes * 8) / 1024 / 1024}")
    
    # Округляем до двух знаков после запятой
    printf "%.2f" "$speed_mbps"
    return 0
}

# ПРОВЕРКА ГЕОЛОКАЦИИ

check_geo() {
    local interface="$1"
    local detail="${2:-}"
    
    # Защита от пустого интерфейса
    if [ -z "$interface" ]; then
        return 1
    fi

    # Выполняем запрос через указанный интерфейс
    local geo_raw
    geo_raw=$(timeout 15s curl -sL --interface "$interface" "http://ip-api.com/line/?fields=status,countryCode,city,query" | tr -d '\r')
    
    local g_status
    g_status=$(echo "$geo_raw" | sed -n '1p')
    local g_country
    g_country=$(echo "$geo_raw" | sed -n '2p' | tr '[:lower:]' '[:upper:]')
    local g_city
    g_city=$(echo "$geo_raw" | sed -n '3p')

    if [ "$g_status" = "success" ] && [ -n "$g_country" ]; then
        if [ "$detail" = "detail" ] && [ -n "$g_city" ]; then
            printf '%s|%s\n' "$g_country" "$g_city"
        else
            echo "$g_country"
        fi
        return 0
    fi
    
    return 1
}


# --- СИСТЕМНЫЕ ФУНКЦИИ (Будут доступны везде) ---

# Универсальное логирование
log_message() {
    local msg="$1"
    local tag="${2:-SYSTEM}" # Если второй параметр не передан, будет [SYSTEM]

    if ! ensure_stats_dir; then
        printf 'Unsafe or missing stats directory: %s (expected root:root 0700)\n' "${STATS_DIR:-unset}" >&2
        return 1
    fi
    
    # Раскрашиваем тег в зависимости от его имени (для удобства чтения)
    local tag_color="$CLR_CYN"
    [[ "$tag" == "BYPASS" ]] && tag_color="$CLR_GRN"
    [[ "$tag" == "STARTER" ]] && tag_color="$CLR_YLW"
    [[ "$tag" == "MONITOR" ]] && tag_color="$CLR_RED"

    # Пишем в лог: [ТЕГ] сообщение (с включенным -e для обработки цветов)
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${tag_color}[$tag]${CLR_RST} $msg" >> "$LOG_RAM"
}

# --- СТАТИСТИКА И УВЕДОМЛЕНИЯ ---

inc_stat() {
    local file="$STATS_DIR/$1"
    ensure_stats_dir || return $?
    local val=$(cat "$file" 2>/dev/null || echo 0)
    echo $((val + 1)) > "$file"
}

send_alert() {
    local type="$1" # CRITICAL / INFO
    local msg="$2"
    local icon="ℹ️"
    [[ "$type" == "CRITICAL" ]] && icon="⚠️"
    debug_log "send tg message: $icon [$type] $msg"
    send_tg "$icon [-$SYSTEM_NAME-] [$type] $msg"
}


check_state_change() {
    local state_name="$1"
    local current_val="$2"
    local alert_msg_ok="$3"
    local alert_msg_fail="$4"
    local state_file="$STATS_DIR/last_$state_name"
    
    local old_val=$(cat "$state_file" 2>/dev/null || echo 1)
    
    if [[ "$old_val" == "1" && "$current_val" == "0" ]]; then
        [ -n "$alert_msg_fail" ] && send_alert "CRITICAL" "$alert_msg_fail"
    elif [[ "$old_val" == "0" && "$current_val" == "1" ]]; then
        # Отправляем только если сообщение не пустое
        [ -n "$alert_msg_ok" ] && send_alert "INFO" "$alert_msg_ok"
    fi
    echo "$current_val" > "$state_file"
}

# Универсальная отправка в ТГ (через внешний скрипт)
# Мы НЕ прописываем здесь curl, чтобы избежать зацикливания, 
# а просто указываем путь к исполнителю.
send_tg() {
    if [ -f "$MAIN_SH_DIR/vpn-tg-send.sh" ]; then
        "$MAIN_SH_DIR/vpn-tg-send.sh" "$1"
    else
        log_message "[ERROR] vpn-tg-send.sh not found!" "[TG-SEND]" 
    fi
}

check_hw_health() {
    local tag="${1:-SYSTEM}"
    local cpu_temp=$("$MAIN_SH_DIR/vpn-hw-check.sh")
    local limit=${TEMP_LIMIT:-75}

    # Если температура 0 или пустая — значит ошибка чтения
    if [ "$cpu_temp" -le 0 ]; then return 0; fi

    local t_state=1
    [ "$cpu_temp" -ge "$limit" ] && t_state=0
    
    # Используем вашу функцию смены состояний
    check_state_change "temp" "$t_state" "Температура стабилизировалась ($cpu_temp°C)" "ПЕРЕГРЕВ ЦП: $cpu_temp°C!" "$tag"
}

check_temp_health() {
    # 1. Получаем температуру и очищаем от всего, кроме цифр
    
    local cpu_temp=$("$MAIN_SH_DIR/vpn-hw-check.sh")
    
    # 2. Берем лимит из конфига или ставим 75 по умолчанию
    local limit=${TEMP_LIMIT:-75}
    debug_log "[DEBUG] Raw Temp: $raw_temp | Parsed: $cpu_temp | Limit: $limit"

    # 3. Проверка на валидность данных перед сравнением
    if [[ -z "$cpu_temp" || ! "$cpu_temp" =~ ^[0-9]+$ ]]; then
        debug_log "${CLR_RED}!! ERROR !! Invalid temperature value: '$cpu_temp'${CLR_RST}"
        return 0
    fi

    local t_state=1
    if [ "$cpu_temp" -ge "$limit" ]; then 
        t_state=0
        debug_log "${CLR_RED}!! ALERT !! Temperature OVER limit!${CLR_RST}"
    else
        debug_log "!! OK !! Temperature is within limits."
    fi
    
    check_state_change "temp" "$t_state" "Температура стабилизировалась ($cpu_temp°C)" "ПЕРЕГРЕВ ЦП: $cpu_temp°C!"
}

