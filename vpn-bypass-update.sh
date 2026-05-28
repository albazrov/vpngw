#!/bin/bash

# version 20260528_01

# RPi4B
# vpn-bypass-update.sh


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

# Локальные переменные для защиты от запуска нескольких копий
LOCK_FILE="/dev/shm/vpn-bypass-update.lock"
DEBUG=true

# --- БЛОКИРОВКА ПАРАЛЛЕЛЬНОГО ЗАПУСКА ---
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [BYPASS] Skip: script already running." >> "$LOG_RAM"
    exit 0
fi

# --- ВНУТРЕННИЕ ФУНКЦИИ ---
# функция log_message определена в "vpn-functions.sh"
debug_log() { $DEBUG && log_message "DEBUG: $1" "BYPASS"; }

setup_infrastructure() {
    debug_log "Checking system infrastructure..." "BYPASS"
    
    [ -d "$STATS_DIR" ] || mkdir -p "$STATS_DIR"
    chmod 777 "$STATS_DIR" 2>/dev/null


    # 1. IP Forwarding (Используем полный путь для надежности в CRON)
    # Форвардинг теперь жестко привязан к 1
    CURRENT_VAL=$(/usr/sbin/sysctl -n net.ipv4.ip_forward | tr -d '[:space:]')
    if [ "$CURRENT_VAL" != "1" ]; then
        debug_log "[FIX] Enabling IP Forwarding..." "BYPASS"
        sudo /usr/sbin/sysctl -w net.ipv4.ip_forward=1 >/dev/null
    fi

    # 2. проход локального трафика мимо всех VPN таблиц
    ip rule show | grep -q "20:" || sudo ip rule add to "$HOME_NET" lookup main priority 20
    ip rule show | grep -q "22:" || sudo ip rule add to "$LOCAL_NET" lookup main priority 22


    # 3. Таблицы и маршруты
    [ -d /etc/iproute2 ] || sudo mkdir -p /etc/iproute2
    # Создаем rt_tables если его нет (merged-usr way)
    if [ ! -f /etc/iproute2/rt_tables ]; then
       echo -e "255\tlocal\n254\tmain\n253\tdefault\n0\tunspec" | sudo tee /etc/iproute2/rt_tables >/dev/null
    fi
    
    # Регистрируем имя таблицы
    if ! grep -q "$TABLE" /etc/iproute2/rt_tables; then
        echo "100 $TABLE" | sudo tee -a /etc/iproute2/rt_tables >/dev/null
    fi

    # ПРОВЕРКА И ДОБАВЛЕНИЕ МАРШРУТА (используем replace для надежности)
    if ! ip route show table "$TABLE" | grep -q "default"; then
        debug_log "[FIX] Adding default route to table $TABLE (100)..." "BYPASS"
        sudo ip route add default via "$GATEWAY" dev "$NET_IF" table "$TABLE"
    else
        # На случай если шлюз изменился, обновляем его
        sudo ip route replace default via "$GATEWAY" dev "$NET_IF" table "$TABLE"
    fi


    # 4. IPSet (Добавлен таймаут и -exist)
    sudo ipset create "$IPSET_NAME" hash:net maxelem 300000 timeout "$IPSET_TIMEOUT" -exist


    # 5. Policy Routing Rule
    if ! ip rule show priority 100 | grep -q "$TABLE"; then
        sudo ip rule add fwmark "$MARK" lookup "$TABLE" priority 100
    fi

    # 6. IPTABLES (Mangle)
    # Исключения для локального трафика в цепочках
    sudo iptables -t mangle -C PREROUTING -d $HOME_NET -j RETURN 2>/dev/null || sudo iptables -t mangle -I PREROUTING -d $HOME_NET -j RETURN
    sudo iptables -t mangle -C OUTPUT -d $HOME_NET -j RETURN 2>/dev/null || sudo iptables -t mangle -I OUTPUT -d $HOME_NET -j RETURN
    
    # Маркировка RU трафика
    sudo iptables -t mangle -C PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK" 2>/dev/null || \
        sudo iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK"
    sudo iptables -t mangle -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK" 2>/dev/null || \
        sudo iptables -t mangle -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK"

    # Маркировка трафика отправки почты по порту 587 или 465, чтобы работало всегда через eth0
    # Проверяем, нет ли уже такого правила, и добавляем
    # Правило для порта 587 (SMTP STARTTLS)
    iptables -t mangle -C OUTPUT -p tcp --dport 587 -j MARK --set-mark 0x371 2>/dev/null || \
        iptables -t mangle -A OUTPUT -p tcp --dport 587 -j MARK --set-mark 0x371

    # Правило для порта 465 (SMTPS / SSL)
    iptables -t mangle -C OUTPUT -p tcp --dport 465 -j MARK --set-mark 0x371 2>/dev/null || \
        iptables -t mangle -A OUTPUT -p tcp --dport 465 -j MARK --set-mark 0x371

    
    iptables -t mangle -C OUTPUT -p tcp --dport 465 -j MARK --set-mark 0x371 2>/dev/null || \
    iptables -t mangle -A OUTPUT -p tcp --dport 465 -j MARK --set-mark 0x371

    # TCPMSS Clamping (важно для MTU в туннелях)
    sudo iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # 7. IPTABLES (Filter/NAT)
    sudo iptables -C FORWARD -s "$LOCAL_NET" -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -s "$LOCAL_NET" -j ACCEPT
    sudo iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Masquerade (ISP)
    sudo iptables -t nat -C POSTROUTING -o "$NET_IF" -m set --match-set "$IPSET_NAME" dst -j MASQUERADE 2>/dev/null || \
        sudo iptables -t nat -I POSTROUTING -o "$NET_IF" -m set --match-set "$IPSET_NAME" dst -j MASQUERADE

    # Masquerade (VPN) - применяется только если туннель поднят
    if ip link show "$VPN_IF" > /dev/null 2>&1; then
        sudo iptables -t nat -C POSTROUTING -o "$VPN_IF" -j MASQUERADE 2>/dev/null || \
            sudo iptables -t nat -A POSTROUTING -o "$VPN_IF" -j MASQUERADE
    else
        debug_log "[WARN] $VPN_IF not found, skipping VPN NAT." "BYPASS"
    fi
}

update_ips() {
    debug_log "Updating IP ranges..." "BYPASS"
    
    # 1. Попытка скачать свежие данные
    # Добавлен флаг -L (редирект) и -4 (IPv4) для стабильности на RPi4
    local raw_data=$(timeout 60s curl -sL4 --interface "$NET_IF" "$SOURCE_URL")
    
    if [ -n "$raw_data" ] && [[ "$raw_data" == *"/"* ]]; then
        local count=$(echo "$raw_data" | grep -c '/')
        # Сохраняем резервную копию на флешку
        echo "$raw_data" > "$IPSET_CACHE"
        
        # Обновляем ipset в памяти
        { echo "flush $IPSET_NAME"; echo "$raw_data" | sed "s/^/add $IPSET_NAME /"; } | sudo ipset restore
        
        debug_log "Success: Downloaded $count ranges from $SOURCE_URL." "BYPASS"
        debug_log "Update successful. Cache updated." "BYPASS"
        return 0
    fi

    # 2. Если скачать не удалось — проверяем память
    debug_log "ERROR: Download failed. Checking alternatives..." "BYPASS"
    local current_entries=$(sudo ipset list "$IPSET_NAME" | grep "Number of entries" | awk '{print $4}' || echo 0)

    if [ "$current_entries" -gt 100 ]; then
        debug_log "Alternative: Keeping $current_entries entries already present in RAM." "BYPASS"
        send_tg "[$SYSTEM_NAME] ⚠️ Не удалось обновить RU-IP. Использую текущую базу из памяти ($current_entries записей)."
        return 0
    fi

    # 3. Если в памяти пусто — проверяем кэш на флешке
    debug_log "Alternative: RAM is empty. Checking disk cache at $IPSET_CACHE..." "BYPASS"
    if [ -f "$IPSET_CACHE" ]; then
        local cache_count=$(grep -c '/' "$IPSET_CACHE")
        local cache_date=$(date -r "$IPSET_CACHE" "+%d.%m.%Y %H:%M")
        
        cat "$IPSET_CACHE" | sed "s/^/add $IPSET_NAME /" | sudo ipset restore
        
        debug_log "Alternative success: Loaded $cache_count ranges from disk cache (dated $cache_date)." "BYPASS"
        send_tg "[$SYSTEM_NAME] ‼️ База не скачана. Загружен кэш с флешки от $cache_date ($cache_count записей)."
        return 0
    else
        # 4. Если всё плохо
        debug_log "CRITICAL: No download, no RAM data, no disk cache found!" "BYPASS"
        send_tg "[$SYSTEM_NAME] 🆘 КРИТИЧЕСКАЯ ОШИБКА: База RU-IP недоступна!"
        return 1
    fi
}


# --- ИСПОЛНЕНИЕ ---
rotate_logs
setup_infrastructure

# Если вызван с параметром 'force' или список пуст — обновляем базу
ENTRIES=$(sudo ipset list "$IPSET_NAME" | grep "Number of entries" | awk '{print $4}' || echo 0)
if [ "$ENTRIES" -eq 0 ] || [ "$1" == "force" ]; then
    update_ips
fi

