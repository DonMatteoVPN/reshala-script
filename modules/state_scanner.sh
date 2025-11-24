#!/bin.bash
# ============================================================ #
# ==             МОДУЛЬ СКАНИРОВАНИЯ REMNAWAVE              == #
# ============================================================ #
# Этот скрипт — детектив. Он ищет Docker-контейнеры,
# определяет версии и докладывает обстановку.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# Глобальные переменные, которые этот модуль будет заполнять для дашборда
SERVER_TYPE="Чистый сервак"; PANEL_VERSION=""; NODE_VERSION=""; BOT_DETECTED=0; BOT_VERSION=""; WEB_SERVER="Не определён";

scan_remnawave_state() {
    # Сбрасываем переменные перед каждым сканированием
    SERVER_TYPE="Чистый сервак"; PANEL_VERSION=""; NODE_VERSION=""; BOT_DETECTED=0; BOT_VERSION=""; WEB_SERVER="Не определён";
    
    local containers; containers=$(docker ps --format '{{.Names}}' 2>/dev/null)
    if [ -z "$containers" ]; then return; fi

    local is_panel=0; local is_node=0; local has_foreign=0;
    
    while IFS= read -r name; do
        case "$name" in
            remnawave-backend*|remnawave-subscription-page*) is_panel=1 ;;
            remnanode*) is_node=1 ;;
            remnawave_bot) BOT_DETECTED=1 ;;
            remnawave-*|tinyauth) ;; # Это наши служебные, их игнорируем для определения типа
            *) has_foreign=1 ;;
        esac
    done <<< "$containers"

    # Определяем ТИП СЕРВЕРА
    if [ $is_panel -eq 1 ] && [ $is_node -eq 1 ]; then SERVER_TYPE="🔥 COMBO (Панель + Нода)"
    elif [ $is_panel -eq 1 ]; then SERVER_TYPE="Панель управления"
    elif [ $is_node -eq 1 ]; then SERVER_TYPE="Боевая Нода"
    elif [ $has_foreign -eq 1 ]; then SERVER_TYPE="НЕ НАЙДЕНО / СТОРОННИЙ СОФТ"
    fi

    # Определяем ВЕРСИИ (через парсинг логов - это хрупко, но другого пути нет)
    if [ $is_panel -eq 1 ]; then
        PANEL_VERSION=$(docker logs remnawave-backend 2>&1 | grep -oE 'Remnawave Backend v[0-9.]+' | tail -n1 | sed 's/Remnawave Backend v//' || echo "N/A")
    fi
    if [ $is_node -eq 1 ]; then
        NODE_VERSION=$(docker logs remnanode 2>&1 | grep -oE 'Remnawave Node v[0-9.]+' | tail -n1 | sed 's/Remnawave Node v//' || echo "N/A")
    fi
    if [ $BOT_DETECTED -eq 1 ]; then
        BOT_VERSION=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$(docker inspect --format '{{.Image}}' remnawave_bot)" 2>/dev/null || echo "N/A")
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-nginx"; then
        local nginx_ver; nginx_ver=$(docker exec remnawave-nginx nginx -v 2>&1 | grep -oE '[0-9.]+' || echo "")
        WEB_SERVER="Nginx ${nginx_ver} (в Docker)"
    fi
}