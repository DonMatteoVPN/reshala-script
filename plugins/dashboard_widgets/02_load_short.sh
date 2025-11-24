#!/bin/bash
# TITLE: Нагрузка сервера (load average)
# Краткий виджет: показывает load average и число ядер.

CORES=$(nproc 2>/dev/null || echo "?")
LOAD=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | cut -d',' -f1 | xargs)

if [ -z "$LOAD" ]; then
  echo "Нагрузка : нет данных"
else
  echo "Нагрузка : $LOAD (ядер: $CORES)"
fi
