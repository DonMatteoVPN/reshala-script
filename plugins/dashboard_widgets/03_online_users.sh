#!/bin/bash
# TITLE: Сетевой движ (TCP)
# Виджет показывает, сколько активных TCP‑подключений есть сейчас.
#
# КАК НАСТРОИТЬ ПОД СЕБЯ:
#   - Если хочешь считать только ESTABLISHED — оставь как есть.
#   - Если нужен полный треш (все состояния) — убери фильтр state established.
#   - Лейбл "TCP-сессии    :" можно переименовать.

if command -v ss &>/dev/null; then
  ESTAB=$(ss -tan state established 2>/dev/null | tail -n +2 | wc -l | xargs)
elif command -v netstat &>/dev/null; then
  ESTAB=$(netstat -tan 2>/dev/null | grep ESTABLISHED | wc -l | xargs)
else
  echo "TCP-сессии    : ss/netstat не найдены"
  exit 0
fi

if [ -z "$ESTAB" ]; then
  echo "TCP-сессии    : нет данных"
  exit 0
fi

echo "TCP-сессии    : $ESTAB активных"
