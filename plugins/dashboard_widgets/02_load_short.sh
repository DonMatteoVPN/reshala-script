#!/bin/bash
# TITLE: Docker: мини-обзор
# Лёгкий виджет: показывает общее состояние Docker по количеству контейнеров.
#
# КАК НАСТРОИТЬ ПОД СЕБЯ:
#   - Если Docker не используешь — просто выключи виджет в меню виджетов.
#   - Можно дописать свои фильтры (например, считать только remnawave-* контейнеры).
#   - Лейбл "Docker        :" можно переименовать, главное оставить двоеточие.

# Проверяем, что docker вообще есть
if ! command -v docker &>/dev/null; then
  echo "Docker: не установлен"
  exit 0
fi

# Считаем контейнеры. Все команды лёгкие, без тяжёлых inspect'ов.
TOTAL=$(docker ps -a -q 2>/dev/null | wc -l | xargs)
RUNNING=$(docker ps -q 2>/dev/null | wc -l | xargs)
RESTARTING=$(docker ps --filter "status=restarting" -q 2>/dev/null | wc -l | xargs)
EXITED=$(docker ps -a --filter "status=exited" -q 2>/dev/null | wc -l | xargs)

if [ -z "$TOTAL" ]; then
  echo "Docker: нет данных"
  exit 0
fi

echo "Docker: всего $TOTAL, живых $RUNNING, рестартится $RESTARTING, мёртвых $EXITED"
