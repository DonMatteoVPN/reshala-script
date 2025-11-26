#!/bin/bash
# TITLE: Проверить диск (/ и тяжёлые каталоги в /var)
# Плагин для Скайнета: показывает использование диска и топ по каталогам.
#

run() {
    echo "===== ДИСК / ====="
    df -h /
    echo ""
    echo "===== ТОП 5 ТЯЖЕЛЫХ КАТАЛОГОВ В /VAR ====="
    if command -v du >/dev/null 2>&1; then
        du -h /var 2>/dev/null | sort -hr | head -n 5
    else
        echo "Утилита du не найдена."
    fi
}

run
