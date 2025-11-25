#!/bin/bash
# TITLE: Настроение сервера
# Забавный, но лёгкий виджет: даёт оценку состояния сервера по аптайму и нагрузке.
#
# КАК НАСТРОИТЬ ПОД СЕБЯ:
#   - Можешь переписать фразы в блоке case на свой фирменный стиль.
#   - Можешь поменять пороговые значения для аптайма/нагрузки.
#   - Лейбл "Настроение     :" можно сменить.

UPTIME_RAW=$(uptime -p 2>/dev/null | sed 's/^up //;s/,//g')
LOAD_RAW=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | cut -d',' -f1 | xargs)
CORES=$(nproc 2>/dev/null || echo 1)

if [[ "$CORES" =~ ^[0-9]+$ ]] && [[ "$CORES" -gt 0 ]] && [[ "$LOAD_RAW" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  REL_LOAD=$(awk -v l="$LOAD_RAW" -v c="$CORES" 'c>0 {printf "%.2f", l/c}')
else
  REL_LOAD="0.0"
fi

MOOD=""
if [[ "$UPTIME_RAW" == *"мин"* ]] || [[ "$UPTIME_RAW" == *"min"* ]]; then
  MOOD="новенький, ещё пахнет заводом"
elif [[ "$UPTIME_RAW" == *"час"* ]] || [[ "$UPTIME_RAW" == *"hour"* ]]; then
  MOOD="разогрет, в боевом режиме"
else
  MOOD="закалённый временем боец"
fi

# Чуть корректируем по нагрузке
CMP_HIGH=$(awk -v x="$REL_LOAD" 'BEGIN{print (x>1.2)?"high":"ok"}')
CMP_LOW=$(awk -v x="$REL_LOAD" 'BEGIN{print (x<0.3)?"low":"ok"}')

if [ "$CMP_HIGH" = "high" ]; then
  MOOD="пыхтит изо всех сил"
elif [ "$CMP_LOW" = "low" ]; then
  MOOD="пинает балду"
fi

echo "Настроение     : $MOOD (аптайм: $UPTIME_RAW, load: $LOAD_RAW/$CORES)"\r\n
echo "Диск /         : $USED ($PERC, $STATUS)"
