#!/bin/bash
# TITLE: Нагрузка и сеть (top по CPU, ip addr/route)
# Плагин для Скайнета: показывает нагрузку и базовую сетевую инфу.
#

run() {
    echo "===== LOAD AVERAGE ====="
    uptime
    echo ""
    echo "===== ТОП-5 ПРОЦЕССОВ ПО CPU ====="
    if command -v ps >/dev/null 2>&1; then
        ps aux --sort=-%cpu | head -n 6
    else
        echo "ps недоступен."
    fi
    echo ""
    echo "===== СЕТЬ (ip -4 addr / route) ====="
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show
        echo ""
        ip route show
    else
        echo "ip недоступен."
    fi
}

run
