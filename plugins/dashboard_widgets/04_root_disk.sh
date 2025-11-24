#!/bin/bash
# TITLE: Диск / (корневая файловая система)
# Показывает использование корневого раздела.

LINE=$(df -h / 2>/dev/null | awk 'NR==2')
USED=$(echo "$LINE" | awk '{print $3 "/" $2}')
PERC=$(echo "$LINE" | awk '{print $5}')

if [ -z "$USED" ]; then
  echo "Диск / : нет данных"
else
  echo "Диск / : $USED ($PERC)"
fi
