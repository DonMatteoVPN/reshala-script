#!/bin/bash
# TITLE: Здоровье диска / (root)
# Виджет показывает использование корневого раздела и словесную оценку.
#
# КАК НАСТРОИТЬ ПОД СЕБЯ:
#   - Пороги заполнения (70/85%) правятся в переменных WARN_PERC и DANGER_PERC.
#   - Тексты статусов ("зеленый", "жёлтый", "КРАСНЫЙ") можно переписать под свой стиль.
#   - При желании можно заменить `/` на другой путь в команде `df -h /`.

LINE=$(df -h / 2>/dev/null | awk 'NR==2')
USED=$(echo "$LINE" | awk '{print $3 "/" $2}')
PERC=$(echo "$LINE" | awk '{print $5}')

if [ -z "$USED" ] || [ -z "$PERC" ]; then
  echo "Диск /         : нет данных"
  exit 0
fi

WARN_PERC=70
DANGER_PERC=85

NUM_PERC=$(echo "$PERC" | tr -d '%' )
STATUS=""

if [[ "$NUM_PERC" =~ ^[0-9]+$ ]]; then
  if [ "$NUM_PERC" -lt "$WARN_PERC" ]; then
    STATUS="зелёный, можно жить"
  elif [ "$NUM_PERC" -lt "$DANGER_PERC" ]; then
    STATUS="жёлтый, подумай о уборке"
  else
    STATUS="КРАСНЫЙ, срочно чистить!"
  fi
else
  STATUS="непонятно, смотри df"
fi

echo "Диск /         : $USED ($PERC, $STATUS)"
