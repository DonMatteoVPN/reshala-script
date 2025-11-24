#!/bin/bash
#
# Виджет для дашборда "Решалы": показывает цену BTC.
#

# API от coingecko, бесплатный и без ключей
API_URL="https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"

# Пытаемся получить цену через curl. Ставим таймаут, чтобы не вешать дашборд.
# jq нужен для парсинга JSON.
if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    # Выполняем запрос и извлекаем цену
    PRICE=$(curl -s --connect-timeout 3 "$API_URL" | jq -r '.bitcoin.usd')
    
    # Проверяем, что получили число
    if [[ "$PRICE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        # Форматируем с разделителями тысяч для красоты
        FORMATTED_PRICE=$(printf "%'.0f" "$PRICE")
        # Выводим результат в формате "Заголовок : Значение"
        echo "BTC Price : \$${FORMATTED_PRICE}"
    else
        # Если API не ответил или вернул ошибку
        echo "BTC Price : API Error"
    fi
else
    # Если на сервере нет curl или jq
    echo "BTC Price : curl/jq missing"
fi