#!/bin/bash
# TITLE: Курс биткоина (BTC)
# Виджет для дашборда "Решалы": показывает цену BTC в USD.
#
# КАК НАСТРОИТЬ ПОД СЕБЯ:
#   - Хочешь другую монету (например ETH) — поменяй `ids=bitcoin` на `ids=ethereum` в API_URL.
#   - Хочешь другую валюту (например EUR или RUB) — поменяй `vs_currencies=usd`.
#   - Текст слева от двоеточия ("Курс BTC       :") — это заголовок виджета в панели.
#

# Бесплатный API CoinGecko, без ключей и регистрации
API_URL="https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"

# 1. Проверяем, что есть curl и jq (иначе красиво вываливаемся)
if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Курс BTC       : curl/jq не установлены"
    exit 0
fi

# 2. Дёргаем API с небольшим таймаутом, чтобы не вешать дашборд
RESPONSE=$(curl -s --connect-timeout 3 "$API_URL")
PRICE=$(echo "$RESPONSE" | jq -r '.bitcoin.usd' 2>/dev/null)

# 3. Проверяем, что из API пришло число, а не ошибка
if [[ "$PRICE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # Округляем до целого и пытаемся красиво отформатировать с разделителями тысяч
    FORMATTED_PRICE=$(printf "%'.0f" "$PRICE" 2>/dev/null || printf "%.0f" "$PRICE")
    # ВАЖНО: никаких {FORMATTED_PRICE} — только подставленное значение
    echo "Курс BTC       : \$${FORMATTED_PRICE}"
else
    # API вернул что-то странное
    echo "Курс BTC       : нет данных (ошибка API)"
fi
