#!/bin/bash

# version 20260528_01

# vpn-hw-check.sh

# Скрипт возвращает ТОЛЬКО целое число градусов

if command -v vcgencmd >/dev/null 2>&1; then
    # Это Raspberry Pi
    vcgencmd measure_temp | tr -cd '0-9.' | cut -d'.' -f1
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    # Это Orange Pi или другой Linux
    raw=$(cat /sys/class/thermal/thermal_zone0/temp)
    echo $((raw / 1000))
else
    # Если не удалось определить
    echo "0"
fi

