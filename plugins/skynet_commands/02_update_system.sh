#!/bin/bash
# TITLE: Обновить систему (apt update && upgrade)
# Плагин для Скайнета: запускает apt update && apt upgrade.
#

run() {
    echo "Запускаю обновление системы (apt)..."
    
    # Проверяем, что это Debian-based система
    if ! command -v apt-get &>/dev/null; then
        echo "Это не Debian/Ubuntu, пропускаю."
        exit 0
    fi
    
    # Запускаем обновление. -y чтобы не спрашивал подтверждения.
    apt-get update -qq && apt-get upgrade -y -qq
    
    echo "Обновление завершено."
}

run