#!/bin/bash
# TITLE: Активные пользователи (ssh/shell)
# Показывает количество активных интерактивных сессий.

COUNT=$(who 2>/dev/null | wc -l | xargs)
if [ -z "$COUNT" ]; then
  echo "Сессии SSH : нет данных"
else
  echo "Сессии SSH : $COUNT"
fi
