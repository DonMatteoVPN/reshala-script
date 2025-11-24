#!/bin/bash
# ============================================================ #
# ==             МОДУЛЬ СКАНИРОВАНИЯ REMNAWAVE              == #
# ============================================================ #
# Этот модуль — детектив. Он ищет Docker-контейнеры Remnawave,
# определяет роли сервера, версии, пути docker-compose и докладывает
# обстановку для дашборда и логов.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# Глобальные переменные, которые мы заполняем для других модулей
SERVER_TYPE="Чистый сервак"
PANEL_VERSION=""
NODE_VERSION=""
PANEL_NODE_PATH=""
BOT_DETECTED=0
BOT_VERSION=""
BOT_PATH=""
WEB_SERVER="Не определён"

# Флаг, чтобы не пересканировать Remnawave/бота на каждом кадре дашборда
REMNA_STATE_SCANNED=0

# НИЖЕ — портированная логика из старого install_reshala.sh

# Проверяет, относится ли имя контейнера к экосистеме Remnawave
_state_is_remnawave_container() {
    local name="$1"
    case "$name" in
        remnawave-*|remnanode*|remnawave_bot|tinyauth|support-*)
            return 0  # Это Remnawave-контейнер
            ;;
        *)
            return 1  # Сторонний
            ;;
    esac
}

# Очистка версии от лишних символов (v, пробелы, мусор для latest)
_state_clean_version() {
    local v="$1"
    # Снимаем префикс v/V и убираем пробелы
    v=$(echo "$v" | sed 's/^[vV]//' | tr -d '[:space:]')
    # Специальный случай: "latest(ненашёлвлогах)" и подобный мусор
    if [[ "$v" == latest* && "$v" != *[0-9]* ]]; then
        echo "latest"
    else
        echo "$v"
    fi
}

# Извлекает версию ноды и Xray из логов
_state_get_node_version_from_logs() {
    local container="$1"
    local logs
    logs=$(run_cmd docker logs --tail 10000 "$container" 2>&1)

    local node_ver
    # Ищем самую свежую запись о версии ноды, допускаем как "v2.2.3", так и "2.2.3"
    node_ver=$(echo "$logs" | grep -oE "Remnawave Node v?[0-9.]+" | tail -n 1 | grep -oE "v?[0-9.]+")

    local xray_ver
    # Аналогично — Xray-core может логировать с или без буквы v
    xray_ver=$(echo "$logs" | grep -oE "Xray-core v?[0-9.]+" | tail -n 1 | grep -oE "v?[0-9.]+")
    if [ -z "$xray_ver" ]; then
        xray_ver=$(echo "$logs" | grep -oE "XRay Core: v?[0-9.]+" | tail -n 1 | grep -oE "v?[0-9.]+")
    fi

    if [ -n "$node_ver" ]; then
        if [ -n "$xray_ver" ]; then
            echo "${node_ver} (Xray: ${xray_ver})"
        else
            echo "${node_ver}"
        fi
    else
        # Логов с версией не нашли — честно говорим, что знаем только, что образ latest
        echo "latest"
    fi
}

# Извлекает версию панели, сканируя логи
_state_get_panel_version_from_logs() {
    local container_names
    container_names=$(run_cmd docker ps --format '{{.Names}}' 2>/dev/null | grep "^remnawave-") || true

    if [ -z "$container_names" ]; then
        echo "latest"
        return
    fi

    local name
    while IFS= read -r name; do
        case "$name" in
            *-nginx|*-redis|*-db|*-bot|*-scheduler|*-processor|*-subscription-page|*-telegram-mini-app|*-tinyauth)
                continue
                ;;
        esac

        local logs
        logs=$(run_cmd docker logs "$name" 2>/dev/null | tail -n 150)
        local panel_ver
        # Берём САМУЮ ПОСЛЕДНЮЮ запись о версии бэкенда
        panel_ver=$(echo "$logs" | grep -oE 'Remnawave Backend v[0-9.]*' | tail -n 1 | sed 's/Remnawave Backend v//')

        if [ -n "$panel_ver" ]; then
            echo "${panel_ver}"
            return
        fi
    done <<< "$container_names"

    if run_cmd docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-subscription-page"; then
        local sub_ver
        sub_ver=$(run_cmd docker logs remnawave-subscription-page 2>/dev/null | grep -oE 'Remnawave Subscription Page v[0-9.]*' | tail -n 1 | sed 's/Remnawave Subscription Page v//')
        if [ -n "$sub_ver" ]; then
            echo "${sub_ver} (sub-page)"
            return
        fi
    fi

    echo "latest"
}

# Универсальное извлечение версии из docker-образа/окружения
_state_get_docker_version() {
    local container_name="$1"
    local version=""

    version=$(run_cmd docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$container_name" 2>/dev/null)
    if [ -n "$version" ]; then echo "$version"; return; fi

    version=$(run_cmd docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null | grep -E '^(APP_VERSION|VERSION)=' | head -n 1 | cut -d'=' -f2)
    if [ -n "$version" ]; then echo "$version"; return; fi

    if run_cmd docker exec "$container_name" test -f /app/package.json 2>/dev/null; then
        version=$(run_cmd docker exec "$container_name" cat /app/package.json 2>/dev/null | jq -r .version 2>/dev/null)
        if [ -n "$version" ] && [ "$version" != "null" ]; then echo "$version"; return; fi
    fi

    if run_cmd docker exec "$container_name" test -f /app/VERSION 2>/dev/null; then
        version=$(run_cmd docker exec "$container_name" cat /app/VERSION 2>/dev/null | tr -d '\r')
        if [ -n "$version" ]; then echo "$version"; return; fi
    fi

    local image_tag
    image_tag=$(run_cmd docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2)
    if [ -n "$image_tag" ] && [ "$image_tag" != "latest" ]; then echo "$image_tag"; return; fi

    local image_id
    image_id=$(run_cmd docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2)
    echo "latest (образ: ${image_id:0:7})"
}

# Главная функция сканирования состояния Remnawave / бота / веб-сервера
scan_remnawave_state() {
    # Если уже сканировали за текущий запуск, просто возвращаем кэшированные значения
    if [[ ${REMNA_STATE_SCANNED:-0} -eq 1 ]]; then
        return
    fi

    SERVER_TYPE="Чистый сервак"
    PANEL_VERSION=""
    NODE_VERSION=""
    PANEL_NODE_PATH=""
    BOT_DETECTED=0
    BOT_VERSION=""
    BOT_PATH=""
    WEB_SERVER="Не определён"

    local container_names
    container_names=$(run_cmd docker ps --format '{{.Names}}' 2>/dev/null) || true

    if [ -z "$container_names" ]; then
        SERVER_TYPE="Чистый сервак"
        return
    fi

    local is_panel=0
    local is_node=0
    local has_foreign=0
    local panel_container=""
    local node_container=""

    while IFS= read -r name; do
        if [[ "$name" == "remnawave-backend"* ]] || [[ "$name" == "remnawave-subscription-page"* ]]; then
            is_panel=1
            if [[ "$name" == *"backend"* ]]; then
                panel_container="$name"
            elif [ -z "$panel_container" ]; then
                panel_container="$name"
            fi
        elif [[ "$name" == "remnanode"* ]]; then
            is_node=1
            node_container="$name"
        elif [[ "$name" == "remnawave_bot" ]]; then
            : # обрабатываем ниже
        else
            if ! _state_is_remnawave_container "$name"; then
                has_foreign=1
            fi
        fi
    done <<< "$container_names"

    if [ $is_panel -eq 1 ] && [ $is_node -eq 1 ]; then
        SERVER_TYPE="Панель и Нода"
        PANEL_NODE_PATH=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$panel_container" 2>/dev/null)
        local raw_p_ver; raw_p_ver=$(_state_get_panel_version_from_logs)
        PANEL_VERSION=$(_state_clean_version "$raw_p_ver")

        local raw_n_ver; raw_n_ver=$(_state_get_node_version_from_logs "$node_container")
        NODE_VERSION=$(_state_clean_version "$raw_n_ver")

    elif [ $is_panel -eq 1 ]; then
        SERVER_TYPE="Панель"
        PANEL_NODE_PATH=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$panel_container" 2>/dev/null)
        local raw_p_ver; raw_p_ver=$(_state_get_panel_version_from_logs)
        PANEL_VERSION=$(_state_clean_version "$raw_p_ver")

    elif [ $is_node -eq 1 ]; then
        SERVER_TYPE="Нода"
        PANEL_NODE_PATH=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$node_container" 2>/dev/null)
        local raw_n_ver; raw_n_ver=$(_state_get_node_version_from_logs "$node_container")
        NODE_VERSION=$(_state_clean_version "$raw_n_ver")

    elif [ $has_foreign -eq 1 ]; then
        SERVER_TYPE="Сервак не целка"
    else
        SERVER_TYPE="Чистый сервак"
    fi

    # Помечаем, что картина мира по Remnawave/боту собрана и её можно переиспользовать
    REMNA_STATE_SCANNED=1

    if echo "$container_names" | grep -q "^remnawave_bot$"; then
        BOT_DETECTED=1
        local bot_compose_path
        bot_compose_path=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "remnawave_bot" 2>/dev/null || true)
        if [ -n "$bot_compose_path" ]; then
            BOT_PATH=$(dirname "$bot_compose_path")
            if [ -f "$BOT_PATH/VERSION" ]; then
                BOT_VERSION=$(cat "$BOT_PATH/VERSION")
            else
                BOT_VERSION=$(_state_get_docker_version "remnawave_bot")
            fi
        else
            BOT_VERSION=$(_state_get_docker_version "remnawave_bot")
        fi
        BOT_VERSION=$(_state_clean_version "$BOT_VERSION")
    fi

    if echo "$container_names" | grep -q "remnawave-nginx"; then
        local nginx_version
        nginx_version=$(run_cmd docker exec remnawave-nginx nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        WEB_SERVER="Nginx $nginx_version (в Docker)"
    elif echo "$container_names" | grep -q "caddy"; then
        local caddy_version
        caddy_version=$(run_cmd docker exec caddy caddy version 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        WEB_SERVER="Caddy $caddy_version (в Docker)"
    elif ss -tlpn 2>/dev/null | grep -q -E 'nginx|caddy|apache2|httpd'; then
        if command -v nginx &>/dev/null; then
            local nginx_version
            nginx_version=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
            WEB_SERVER="Nginx $nginx_version (на хосте)"
        else
            WEB_SERVER=$(ss -tlpn 2>/dev/null | grep -E 'nginx|caddy|apache2|httpd' | head -n 1 | sed -n 's/.*users:(("\([^"]*\)".*))/\2/p')
        fi
    fi
}
