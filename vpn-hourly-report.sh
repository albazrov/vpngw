#!/bin/bash

# version 20260528_01

# RPi4B 
# vpn-hourly-report.sh

# 1. Подключаем основной конфигурационный файл
CONF_FILE="/etc/vpn-gw.conf"
if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
else
    echo "Ошибка: Конфигурационный файл $CONF_FILE не найден!" >&2
    exit 1
fi

# 2. Динамически подключаем библиотеку функций, используя переменную пути из конфига
FUNCTIONS_LIB="$MAIN_SH_DIR/vpn-functions.sh"
if [ -f "$FUNCTIONS_LIB" ]; then
    # shellcheck disable=SC1090
    source "$FUNCTIONS_LIB"
else
    echo "Ошибка: Библиотека функций $FUNCTIONS_LIB не найдена!" >&2
    exit 1
fi

if ! ensure_stats_dir; then
    printf 'Unsafe or missing stats directory: %s (expected root:root 0700)\n' "$STATS_DIR" >&2
    exit 1
fi

NOW_SEC=$(date +%s)

# Функция проверки индивидуальных интервалов времени отправки
should_send() {
    local enabled="$1"
    local interval_min="$2"
    local label_file="$3"

    [ "$enabled" != "true" ] && return 1
    [ ! -f "$label_file" ] && return 0  # Если файла-метки нет — шлем сразу

    local last_send
    last_send=$(cat "$label_file" 2>/dev/null || echo 0)
    local elapsed_min=$(( (NOW_SEC - last_send) / 60 ))

    if [ "$elapsed_min" -ge "$interval_min" ]; then
        return 0
    fi
    return 1
}

# 1. Сбор системных данных
DATE_NOW=$(date "+%d.%m.%Y")
TIME_NOW=$(date "+%H:%M")
TIME_RANGE="$(date -d '1 hour ago' '+%H:00') - $(date '+%H:00')"

# --- ВСТРОЕННЫЙ ВАШ НАДЕЖНЫЙ БЛОК ГЕО-ДАННЫХ ---
GEO_RAW=$(timeout 15s curl -sL --interface "$VPN_IF" "http://ip-api.com/line/?fields=status,countryCode,query" | tr -d '\r')

G_STATUS=$(echo "$GEO_RAW" | sed -n '1p')
if [ "$G_STATUS" = "success" ]; then
    CUR_ISO=$(echo "$GEO_RAW" | sed -n '2p' | tr '[:lower:]' '[:upper:]')
    CUR_IP=$(echo "$GEO_RAW" | sed -n '3p')
else
    CUR_IP="offline"
    CUR_ISO="??"
fi
# -----------------------------------------------

# Сбор параметров RAM
MEM_INFO=$(free -m | grep Mem)
MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')
MEM_FREE=$(echo "$MEM_INFO" | awk '{print $7}')
MEM_PCT=$(( 100 * MEM_FREE / MEM_TOTAL ))

# Сбор параметров Диска
DISK_INFO=$(df -h "$LOG_DISK" | tail -1)
DISK_FREE=$(echo "$DISK_INFO" | awk '{print $4}')
DISK_PCT=$(echo "$DISK_INFO" | awk '{print $5}' | tr -d '%')
DISK_PCT_FREE=$(( 100 - DISK_PCT ))

# Статистика и инфраструктура
# Безопасный подсчет количества записей в ipset
if sudo ipset list "$IPSET_NAME" >/dev/null 2>&1; then
    RESET_COUNT=$(sudo ipset list "$IPSET_NAME" | grep "Number of entries" | awk '{print $4}')
    [ -n "$RESET_COUNT" ] && IPSET_COUNT="$RESET_COUNT" || IPSET_COUNT="0"
else
    IPSET_COUNT="0"
fi

CHECKS=$(cat "$STATS_DIR/cnt_checks" 2>/dev/null || echo 0)
SUCCESS=$(cat "$STATS_DIR/cnt_success" 2>/dev/null || echo 0)
RECON=$(cat "$STATS_DIR/cnt_recon" 2>/dev/null || echo 0)
CPU_TEMP=$("$MAIN_SH_DIR/vpn-hw-check.sh" 2>/dev/null || echo "??")
UPTIME=$(uptime -p | sed 's/up //')

# Анализ состояния авторизации
if [ -f "$AUTH_FLAG" ]; then
    ELAPSED=$(( $(date +%s) - $(stat -c %Y "$AUTH_FLAG") ))
    REMAINING=$(( (1800 - ELAPSED) / 60 ))
    [ "$REMAINING" -lt 0 ] && REMAINING=0
    AUTH_STATE="⏳ Ожидание (истечет через ${REMAINING} мин)"
else
    AUTH_STATE="✅ OK"
fi

# === 2. БЛОК ОТПРАВКИ В TELEGRAM ===
if should_send "$REPORT_TO_TG" "$REPORT_TG_INTERVAL" "$TG_LAST_SEND_FILE"; then
    REPORT="🖥 *$SYSTEM_NAME* | 📊 *Отчет за $REPORT_TG_INTERVAL мин*
📅 $DATE_NOW | 🕒 $TIME_NOW
🌐 *VPN:* $CUR_IP ($CUR_ISO)
--------------------------
📊 *Статистика:*
🔑 Статус аккаунта: *$AUTH_STATE*
✅ Успешных проверок: *$SUCCESS / $CHECKS*
🔄 Переподключений: *$RECON*
🌡 Температура CPU: *$CPU_TEMP°C*
🇷🇺 База RU-IP: *$IPSET_COUNT записей*

🧠 *Оперативная память:*
Свободно: *$MEM_FREE МБ ($MEM_PCT%)*

💾 *Внешний диск (Логи):*
Свободно: *$DISK_FREE ($DISK_PCT_FREE%)*

⏱ Аптайм: *$UPTIME*"

    send_tg "$REPORT"
    echo "$NOW_SEC" > "$TG_LAST_SEND_FILE"
    log_message "Report successfully sent to Telegram (Interval: ${REPORT_TG_INTERVAL}m)" "REPORT"
fi

# === 3. БЛОК ОТПРАВКИ НА EMAIL ===
if should_send "$REPORT_TO_EMAIL" "$REPORT_EMAIL_INTERVAL" "$EM_LAST_SEND_FILE"; then
    EMAIL_SUBJECT="[ REPORT ] Накопительный отчет шлюза $SYSTEM_NAME за $REPORT_EMAIL_INTERVAL мин"
    
    # Формируем чистый текст для почты без Markdown-звезд
    EMAIL_REPORT="Сводный отчет о работе VPN шлюза ($SYSTEM_NAME)
------------------------------------
📅 Дата: $DATE_NOW | Время: $TIME_NOW | Период: $TIME_RANGE
🌐 Текущий VPN IP: $CUR_IP ($CUR_ISO)
⏱ Аптайм системы: $UPTIME
------------------------------------
🔑 Статус аккаунта: $AUTH_STATE
✅ Всего проверок в базе: $SUCCESS / $CHECKS
🔄 Переподключений за период: $RECON
🌡 Температура CPU: $CPU_TEMP°C
🇷🇺 Объем базы RU-IP: $IPSET_COUNT записей
🧠 Свободная RAM: $MEM_FREE МБ ($MEM_PCT%)
💾 Свободно на Flash: $DISK_FREE ($DISK_PCT_FREE%)"

    if "$MAIN_SH_DIR/vpn-email-send.sh" "$EMAIL_SUBJECT" "$EMAIL_REPORT"; then
        echo "$NOW_SEC" > "$EM_LAST_SEND_FILE"
        log_message "Accumulated report successfully sent to Email (Interval: ${REPORT_EMAIL_INTERVAL}m)" "REPORT"
        
        # СБРОС СЧЕТЧИКОВ СТАТИСТИКИ (Происходит строго при успешной отправке накопительного Email-отчета)
        echo 0 > "$STATS_DIR/cnt_checks"
        echo 0 > "$STATS_DIR/cnt_success"
        echo 0 > "$STATS_DIR/cnt_recon"
        echo 0 > "$STATS_DIR/current_try_count"
    fi
fi

# === 4. ЕЖЕЧАСНЫЙ СБРОС ЖИВЫХ ЛОГОВ НА ФЛЕШКУ ===
# Выполняется строго один раз в час (в районе 55-59 минут каждого часа)
if [ "$(date +%M)" -ge 55 ]; then
    if [ -f "/dev/shm/vpn_stats/vpn-live.log" ]; then
        cat /dev/shm/vpn_stats/vpn-live.log >> /mnt/external_data/vpn-gateway.log
        : > /dev/shm/vpn_stats/vpn-live.log
    fi
fi
