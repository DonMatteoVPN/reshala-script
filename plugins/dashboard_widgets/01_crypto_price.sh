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
# Сразу берём и USD, и RUB, чтобы показать курс в двух валютах.
API_URL="https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd,rub"

# 1. Проверяем, что есть curl и jq (иначе красиво вываливаемся)
if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Курс BTC: curl/jq не установлены"
    exit 0
fi

# 2. Дёргаем API с небольшим таймаутом, чтобы не вешать дашборд
RESPONSE=$(curl -s --connect-timeout 3 "$API_URL")
PRICE_USD=$(echo "$RESPONSE" | jq -r '.bitcoin.usd' 2>/dev/null)
PRICE_RUB=$(echo "$RESPONSE" | jq -r '.bitcoin.rub' 2>/dev/null)

# 3. Проверяем, что из API пришли числа, а не ошибки
if [[ "$PRICE_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    USD_FMT=$(printf "%'.0f" "$PRICE_USD" 2>/dev/null || printf "%.0f" "$PRICE_USD")
else
    USD_FMT="?"
fi

if [[ "$PRICE_RUB" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    RUB_FMT=$(printf "%'.0f" "$PRICE_RUB" 2>/dev/null || printf "%.0f" "$PRICE_RUB")
else
    RUB_FMT="?"
fi

# 4. Собираем финальную строку. Если по одной из валют нет данных — помечаем знаком вопроса.
if [[ "$USD_FMT" == "?" && "$RUB_FMT" == "?" ]]; then
    echo "Курс BTC: нет данных (ошибка API)"
else
    # Формат: Курс BTC: $86 953 / ₽7 950 000
    echo "Курс BTC: \$${USD_FMT} / ₽${RUB_FMT}"
fi
