#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v0.3552 dev - FINAL CUT         ==
# ============================================================ #
# ==    Финальный редизайн, исправлены баги отображения.     ==
# ==    Переработана система логирования.                    ==
# ============================================================ #

set -euo pipefail

# --- КОНСТАНТЫ И ПЕРЕМЕННЫЕ ---
readonly VERSION="v0.3552 dev"
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/dev/install_reshala.sh"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala_ops.log"
INSTALL_PATH="/usr/local/bin/reshala"

# Цвета (стандартные, работают везде)
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_GRAY='\033[0;90m';

# Глобальные переменные
SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён";
UPDATE_AVAILABLE=0; LATEST_VERSION=""; UPDATE_CHECK_STATUS="OK";

# --- УТИЛИТАРНЫЕ ФУНКЦИИ ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | sudo tee -a "$LOGFILE"; }
wait_for_enter() { read -p $'\nНажми Enter, чтобы продолжить...'; }
save_path() { local key="$1"; local value="$2"; touch "$CONFIG_FILE"; sed -i "/^$key=/d" "$CONFIG_FILE"; echo "$key=\"$value\"" >> "$CONFIG_FILE"; }
load_path() { local key="$1"; [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" &>/dev/null; eval echo "\${$key:-}"; }
get_net_status() {
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")
    local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a")
    if [ -z "$qdisc" ] || [ "$qdisc" = "pfifo_fast" ]; then qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n 1) || qdisc="n/a"; fi
    echo "$cc|$qdisc"
}

# --- ФУНКЦИЯ УСТАНОВКИ / ОБНОВЛЕНИЯ ---
install_script() {
    if [[ $EUID -ne 0 ]]; then echo -e "${C_RED}❌ Эту команду — только с 'sudo'.${C_RESET}"; exit 1; fi
    
    echo -e "${C_CYAN}🚀 Интегрирую Решалу ${VERSION} в систему...${C_RESET}"
    
    local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    if ! wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL"; then
        echo -e "${C_RED}❌ Не могу скачать последнюю версию. Проверь интернет или ссылку.${C_RESET}"; exit 1;
    fi
    
    sudo cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && sudo chmod +x "$INSTALL_PATH"
    rm "$TEMP_SCRIPT"

    if ! grep -q "alias reshala='sudo reshala'" /root/.bashrc 2>/dev/null; then
        echo "alias reshala='sudo reshala'" | sudo tee -a /root/.bashrc >/dev/null
    fi

    echo -e "\n${C_GREEN}✅ Готово. Решала в системе.${C_RESET}\n"
    
    if [[ $(id -u) -eq 0 ]]; then
        echo -e "   ${C_BOLD}Команда запуска:${C_RESET} ${C_YELLOW}reshala${C_RESET}"
    else
        echo -e "   ${C_BOLD}Команда запуска:${C_RESET} ${C_YELLOW}sudo reshala${C_RESET}"
    fi

    echo -e "   ${C_RED}⚠️ ВАЖНО: ПЕРЕПОДКЛЮЧИСЬ к серверу, чтобы команда заработала.${C_RESET}"
    if [[ "${1:-}" != "update" ]]; then
        echo -e "   Установочный файл ('$0') можешь сносить."
    fi
}

# --- МОДУЛЬ ОБНОВЛЕНИЯ (С ЧИСТЫМИ ЛОГАМИ И САНАЦИЕЙ) ---
check_for_updates() {
    UPDATE_AVAILABLE=0
    LATEST_VERSION=""
    UPDATE_CHECK_STATUS="OK"
    
    local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
    local curl_error_output; curl_error_output=$(mktemp)
    
    local response_body; response_body=$(curl -4 -L -sS --connect-timeout 7 --max-time 15 --retry 2 --retry-delay 3 \
        "$url_with_buster" 2> "$curl_error_output")
    local curl_exit_code=$?
    
    if [ $curl_exit_code -eq 0 ] && [ -n "$response_body" ]; then
        LATEST_VERSION=$(echo "$response_body" | grep -m 1 'readonly VERSION' | cut -d'"' -f2 | tr -d '\r')
        if [ -n "$LATEST_VERSION" ]; then
            local local_ver_num; local_ver_num=$(echo "$VERSION" | sed 's/[^0-9.]*//g')
            local remote_ver_num; remote_ver_num=$(echo "$LATEST_VERSION" | sed 's/[^0-9.]*//g')

            if [[ "$local_ver_num" != "$remote_ver_num" ]]; then
                local highest_ver_num; highest_ver_num=$(printf '%s\n%s' "$local_ver_num" "$remote_ver_num" | sort -V | tail -n1)
                if [[ "$highest_ver_num" == "$remote_ver_num" ]]; then
                    UPDATE_AVAILABLE=1
                    log "🔥 Обнаружена новая версия: $LATEST_VERSION (Локальная: $VERSION)"
                fi
            fi
        fi
    else
        UPDATE_CHECK_STATUS="ERROR"
        log "❌ Ошибка проверки обновлений. Код: $curl_exit_code. Ответ curl: $(cat "$curl_error_output")"
    fi
    rm -f "$curl_error_output"
}

run_update() {
    read -p "   Доступна версия $LATEST_VERSION. Обновляемся, или дальше на старье пердеть будем? (y/n): " confirm_update
    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then
        echo -e "${C_YELLOW}🤷‍♂️ Ну и сиди со старьём. Твоё дело.${C_RESET}"; wait_for_enter
        return
    fi

    echo -e "${C_CYAN}🔄 Качаю свежак...${C_RESET}"
    local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
    
    if ! wget -4 --timeout=20 --tries=3 --retry-connrefused -q -O "$TEMP_SCRIPT" "$url_with_buster"; then
        echo -e "${C_RED}❌ Хуйня какая-то. Не могу скачать обнову. Проверь инет и лог.${C_RESET}"; 
        log "wget не смог скачать $url_with_buster"
        rm -f "$TEMP_SCRIPT"; wait_for_enter
        return
    fi

    local downloaded_version; downloaded_version=$(grep -m 1 'readonly VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2 | tr -d '\r')
    if [ ! -s "$TEMP_SCRIPT" ] || ! bash -n "$TEMP_SCRIPT" 2>/dev/null || [ "$downloaded_version" != "$LATEST_VERSION" ]; then
        echo -e "${C_RED}❌ Скачалось какое-то дерьмо, а не скрипт. Отбой.${C_RESET}"; 
        log "Скачанный файл обновления не прошел проверку. Ожидалась версия '$LATEST_VERSION', в файле '$downloaded_version'."
        rm -f "$TEMP_SCRIPT"; wait_for_enter
        return
    fi
    
    echo "   Ставлю на место старого..."
    sudo cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && sudo chmod +x "$INSTALL_PATH"
    rm "$TEMP_SCRIPT"

    log "✅ Ахуенный пацан! Успешно обновился с $VERSION до $LATEST_VERSION."
    printf "${C_GREEN}✅ Готово. Теперь у тебя версия %s. Не благодари.${C_RESET}\n" "$LATEST_VERSION"
    echo "   Перезапускаю себя, чтобы мозги встали на место..."
    sleep 2
    exec "$INSTALL_PATH"
}


# --- МОДУЛЬ АВТООПРЕДЕЛЕНИЯ (УСИЛЕННЫЙ) ---
get_docker_version() {
    local container_name="$1"
    local version=""
    version=$(sudo docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$container_name" 2>/dev/null)
    if [ -n "$version" ]; then echo "$version"; return; fi
    version=$(sudo docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null | grep -E '^(APP_VERSION|VERSION)=' | head -n 1 | cut -d'=' -f2)
    if [ -n "$version" ]; then echo "$version"; return; fi
    if sudo docker exec "$container_name" test -f /app/package.json 2>/dev/null; then
        version=$(sudo docker exec "$container_name" cat /app/package.json 2>/dev/null | jq -r .version 2>/dev/null)
        if [ -n "$version" ] && [ "$version" != "null" ]; then echo "$version"; return; fi
    fi
    if sudo docker exec "$container_name" test -f /app/VERSION 2>/dev/null; then
        version=$(sudo docker exec "$container_name" cat /app/VERSION 2>/dev/null | tr -d '\n\r')
        if [ -n "$version" ]; then echo "$version"; return; fi
    fi
    local image_tag; image_tag=$(sudo docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2)
    if [ -n "$image_tag" ] && [ "$image_tag" != "latest" ]; then
        echo "$image_tag"; return;
    fi
    local image_id; image_id=$(sudo docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2)
    echo "latest (образ: ${image_id:0:7})"
}

scan_server_state() {
    SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён"
    local panel_node_container=""
    if sudo docker ps --format '{{.Names}}' | grep -q "^remnawave$"; then
        SERVER_TYPE="Панель"; panel_node_container="remnawave"
    elif sudo docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then
        SERVER_TYPE="Нода"; panel_node_container="remnanode"
    fi
    if [ -n "$panel_node_container" ]; then
        PANEL_NODE_PATH=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$panel_node_container" 2>/dev/null)
        PANEL_NODE_VERSION=$(get_docker_version "$panel_node_container")
    fi
    local bot_container_name="remnawave_bot"
    if sudo docker ps --format '{{.Names}}' | grep -q "^${bot_container_name}$"; then
        BOT_DETECTED=1
        local bot_compose_path; bot_compose_path=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$bot_container_name" 2>/dev/null || true)
        if [ -n "$bot_compose_path" ]; then
            BOT_PATH=$(dirname "$bot_compose_path")
            if [ -f "$BOT_PATH/VERSION" ]; then
                BOT_VERSION=$(cat "$BOT_PATH/VERSION")
            else
                BOT_VERSION=$(get_docker_version "$bot_container_name")
            fi
        else
            BOT_VERSION=$(get_docker_version "$bot_container_name")
        fi
    fi
    if sudo docker ps --format '{{.Names}}' | grep -q "remnawave-nginx"; then
        local nginx_version; nginx_version=$(sudo docker exec remnawave-nginx nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        WEB_SERVER="Nginx $nginx_version (в Docker)"
    elif sudo docker ps --format '{{.Names}}' | grep -q "caddy"; then
        local caddy_version; caddy_version=$(sudo docker exec caddy caddy version 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        WEB_SERVER="Caddy $caddy_version (в Docker)"
    elif ss -tlpn | grep -q -E 'nginx|caddy|apache2|httpd'; then
        if command -v nginx &> /dev/null; then
            local nginx_version; nginx_version=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
            WEB_SERVER="Nginx $nginx_version (на хосте)"
        else
            WEB_SERVER=$(ss -tlpn | grep -E 'nginx|caddy|apache2|httpd' | head -n 1 | sed -n 's/.*users:(("\([^"]*\)".*))/\2/p')
        fi
    fi
}

# --- НОВЫЕ ФУНКЦИИ ДЛЯ СБОРА ИНФОРМАЦИИ О СЕРВЕРЕ ---
get_cpu_info() {
    local model; model=$(lscpu | grep "Model name" | sed 's/.*Model name:[[:space:]]*//' | sed 's/ @.*//')
    local freq; freq=$(lscpu | grep "CPU MHz" | head -n1 | awk '{printf "%.2f GHz", $3/1000}')
    echo "$model ($freq)"
}
get_ram_info() {
    free -m | grep Mem | awk '{printf "%.1f/%.1f GB", $3/1024, $2/1024}'
}
get_hoster_info() {
    curl -s --connect-timeout 5 ipinfo.io/org || echo "Не определён"
}

# --- ОСНОВНЫЕ МОДУЛИ СКРИПТА ---
apply_bbr() {
    log "🚀 ЗАПУСК ТУРБОНАДДУВА (BBR/CAKE)..."
    local net_status; net_status=$(get_net_status)
    local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1)
    local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2)
    local cake_available; cake_available=$(modprobe sch_cake &>/dev/null && echo "true" || echo "false")

    echo "--- ДИАГНОСТИКА ТВОЕГО ДВИГАТЕЛЯ ---"; echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"; echo "------------------------------------"

    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then
        echo -e "${C_GREEN}✅ Ты уже на максимальном форсаже (BBR+CAKE). Не мешай машине работать.${C_RESET}"; log "Проверка «Форсаж»: Максимум."; return
    fi

    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "fq" && "$cake_available" == "true" ]]; then
        echo -e "${C_YELLOW}⚠️ У тебя неплохо (BBR+FQ), но можно лучше. CAKE доступен.${C_RESET}"
        read -p "   Хочешь проапгрейдиться до CAKE? Это топчик. (y/n): " upgrade_confirm
        if [[ "$upgrade_confirm" != "y" && "$upgrade_confirm" != "Y" ]]; then
            echo "Как скажешь. Остаёмся на FQ."; return
        fi
        echo "Красава. Делаем как надо."
    elif [[ "$current_cc" != "bbr" && "$current_cc" != "bbr2" ]]; then
        echo "Хм, ездишь на стоке. Пора залить ракетное топливо."
    fi

    local available_cc; available_cc=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}')
    local preferred_cc="bbr"; if [[ "$available_cc" == *"bbr2"* ]]; then preferred_cc="bbr2"; fi
    
    local preferred_qdisc="fq"
    if [[ "$cake_available" == "true" ]]; then 
        preferred_qdisc="cake"
    else
        log "⚠️ 'cake' не найден, ставлю 'fq'."
        modprobe sch_fq &>/dev/null
    fi

    local tcp_fastopen_val=0; [[ $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0) -ge 1 ]] && tcp_fastopen_val=3
    local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"
    log "🧹 Чищу старое говно..."; sudo rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf
    if [ -f /etc/sysctl.conf.bak ]; then sudo rm /etc/sysctl.conf.bak; fi
    sudo sed -i.bak -E 's/^[[:space:]]*(net.core.default_qdisc|net.ipv4.tcp_congestion_control)/#&/' /etc/sysctl.conf
    log "✍️  Устанавливаю новые, пиздатые настройки..."
    echo "# === КОНФИГ «ФОРСАЖ» ОТ РЕШАЛЫ — НЕ ТРОГАТЬ ===
net.ipv4.tcp_congestion_control = $preferred_cc
net.core.default_qdisc = $preferred_qdisc
net.ipv4.tcp_fastopen = $tcp_fastopen_val
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216" | sudo tee "$CONFIG_SYSCTL" > /dev/null
    log "🔥 Применяю настройки..."; sudo sysctl -p "$CONFIG_SYSCTL" >/dev/null
    echo ""; echo "--- КОНТРОЛЬНЫЙ ВЫСТРЕЛ ---"; echo "Новый алгоритм: $(sysctl -n net.ipv4.tcp_congestion_control)"; echo "Новый планировщик: $(sysctl -n net.core.default_qdisc)"; echo "---------------------------"
    echo -e "${C_GREEN}✅ Твоя тачка теперь — ракета. (CC: $preferred_cc, QDisc: $preferred_qdisc)${C_RESET}";
}

check_ipv6_status() {
    if [ ! -d "/proc/sys/net/ipv6" ]; then
        echo -e "${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"
    elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then
        echo -e "${C_RED}КАСТРИРОВАН${C_RESET}"
    else
        echo -e "${C_GREEN}ВКЛЮЧЁН${C_RESET}"
    fi
}
disable_ipv6() {
    if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "❌ ${C_YELLOW}Тут нечего отключать. Провайдер уже всё отрезал за тебя.${C_RESET}"; return; fi
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo "⚠️ IPv6 уже кастрирован."; return; fi
    echo "🔪 Кастрирую IPv6... Это не больно. Почти."
    sudo tee /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ОТКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOL
    sudo sysctl -p /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null
    log "-> IPv6 кастрирован через sysctl."
    echo -e "${C_GREEN}✅ Готово. Теперь эта тачка ездит только на нормальном топливе.${C_RESET}"
}
enable_ipv6() {
    if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "❌ ${C_YELLOW}Тут нечего включать. Я не могу пришить то, что отрезано с корнем.${C_RESET}"; return; fi
    if [ ! -f /etc/sysctl.d/98-reshala-disable-ipv6.conf ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 0 ]; then
        echo "✅ IPv6 и так работает. Не мешай ему."; return;
    fi
    echo "💉 Возвращаю всё как было... Реанимация IPv6."
    sudo rm -f /etc/sysctl.d/98-reshala-disable-ipv6.conf
    
    sudo tee /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ВКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOL
    sudo sysctl -p /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null
    sudo rm -f /etc/sysctl.d/98-reshala-enable-ipv6.conf
    
    log "-> IPv6 реанимирован."
    echo -e "${C_GREEN}✅ РЕАНИМАЦИЯ ЗАВЕРШЕНА.${C_RESET}"
}
ipv6_menu() {
    while true; do
        clear; echo "--- УПРАВЛЕНИЕ IPv6 ---"; echo -e "Статус IPv6: $(check_ipv6_status)"; echo "--------------------------"; echo "   1. Кастрировать (Отключить)"; echo "   2. Реанимировать (Включить)"; echo "   b. Назад в главное меню"; read -r -p "Твой выбор: " choice
        case $choice in 1) disable_ipv6; wait_for_enter;; 2) enable_ipv6; wait_for_enter;; [bB]) break;; *) echo "1, 2 или 'b'. Не тупи."; sleep 2;; esac
    done
}
view_logs_realtime() {
    local log_path="$1"; local log_name="$2"
    if [ ! -f "$log_path" ]; then echo -e "❌ ${C_RED}Лог '$log_name' пуст.${C_RESET}"; sleep 2; return; fi
    echo "[*] Смотрю журнал '$log_name'... (CTRL+C, чтобы свалить)";
    local original_int_handler=$(trap -p INT)
    trap "echo -e '\n${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT
    (sudo tail -f -n 50 "$log_path" | awk -F ' - ' -v C_YELLOW="$C_YELLOW" -v C_RESET="$C_RESET" '{print C_YELLOW $1 C_RESET "  " $2}') || true
    if [ -n "$original_int_handler" ]; then
        eval "$original_int_handler"
    else
        trap - INT
    fi
    return 0
}
view_docker_logs() {
    local service_path="$1"; local service_name="$2"
    if [ -z "$service_path" ] || [ ! -f "$service_path" ]; then echo -e "❌ ${C_RED}Путь — хуйня.${C_RESET}"; sleep 2; return; fi
    echo "[*] Смотрю потроха '$service_name'... (CTRL+C, чтобы свалить)";
    local original_int_handler=$(trap -p INT)
    trap "echo -e '\n${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT
    (cd "$(dirname "$service_path")" && sudo docker compose logs -f) || true
    if [ -n "$original_int_handler" ]; then
        eval "$original_int_handler"
    else
        trap - INT
    fi
    return 0
}
security_placeholder() {
    clear; echo -e "${C_RED}Написано же, блядь — ${C_YELLOW}В РАЗРАБОТКЕ${C_RESET}. Не лезь.";
}
uninstall_script() {
    echo -e "${C_RED}Точно хочешь выгнать Решалу?${C_RESET}"; read -p "Это снесёт скрипт, конфиги и алиасы. (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "Правильное решение."; wait_for_enter; return; fi
    echo "Прощай, босс. Начинаю самоликвидацию...";
    if [ -f "$INSTALL_PATH" ]; then sudo rm -f "$INSTALL_PATH"; echo "✅ Главный файл снесён."; log "-> Скрипт удалён."; fi
    if [ -f "/root/.bashrc" ]; then sudo sed -i "/alias reshala='sudo reshala'/d" /root/.bashrc; echo "✅ Алиас выпилен."; log "-> Алиас удалён."; fi
    if [ -f "$CONFIG_FILE" ]; then rm -f "$CONFIG_FILE"; echo "✅ Конфиг стёрт."; log "-> Конфиг удалён."; fi
    if [ -f "$LOGFILE" ]; then sudo rm -f "$LOGFILE"; echo "✅ Журнал сожжён."; fi
    echo -e "${C_GREEN}✅ Самоликвидация завершена.${C_RESET}"; echo "   Переподключись, чтобы алиас 'reshala' сдох."; exit 0
}

# --- ИНФО-ПАНЕЛЬ И ГЛАВНОЕ МЕНЮ (НОВЫЙ ДИЗАЙН) ---
display_header() {
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}')
    local net_status; net_status=$(get_net_status)
    local cc; cc=$(echo "$net_status" | cut -d'|' -f1)
    local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2)
    local cc_status; if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}МАКСИМУМ ($cc + $qdisc)${C_RESET}"; else cc_status="${C_GREEN}АКТИВЕН ($cc + $qdisc)${C_RESET}"; fi; else cc_status="${C_YELLOW}СТОК ($cc)${C_RESET}"; fi
    local ipv6_status; ipv6_status=$(check_ipv6_status)
    local cpu_info; cpu_info=$(get_cpu_info)
    local ram_info; ram_info=$(get_ram_info)
    local hoster_info; hoster_info=$(get_hoster_info)

    clear
    echo -e "${C_CYAN}╔═══════════ ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ═══════════╗${C_RESET}"
    if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then 
        printf "║ ${C_YELLOW}%-64s${C_RESET} ║\n" "🔥 Новая версия на подходе: ${LATEST_VERSION}"
    elif [[ "$UPDATE_CHECK_STATUS" != "OK" ]]; then 
        printf "║ ${C_RED}%-64s${C_RESET} ║\n" "⚠️ Не могу проверить обновления. Проблемы со связью."
    fi
    echo -e "${C_CYAN}╠═══════════════════ ИНФО ПО СЕРВЕРУ ══════════════════════╣${C_RESET}"
    printf "║ ${C_GRAY}%-15s${C_RESET} : ${C_YELLOW}%-45s${C_RESET} ║\n" "IP Адрес" "$ip_addr"
    printf "║ ${C_GRAY}%-15s${C_RESET} : ${C_CYAN}%-45s${C_RESET} ║\n" "Хостер" "$hoster_info"
    printf "║ ${C_GRAY}%-15s${C_RESET} : ${C_CYAN}%-45s${C_RESET} ║\n" "Процессор" "$cpu_info"
    printf "║ ${C_GRAY}%-15s${C_RESET} : ${C_CYAN}%-45s${C_RESET} ║\n" "Оперативка" "$ram_info"
    echo -e "${C_CYAN}╠════════════════════ СТАТУС СИСТЕМ ═══════════════════════╣${C_RESET}"
    if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then
        printf "║ ${C_GRAY}%-15s${C_RESET} : ${C_YELLOW}%-45s${C_RESET} ║\n" "Тип установки" "$SERVER_TYPE v$PANEL_NODE_VERSION"
    else
        printf "║ ${C_GRAY}%-15s${C_RESET} : ${C_YELLOW}%-45s${C_RESET} ║\n" "Тип установки" "$SERVER_TYPE"
    fi
    if [ "$BOT_DETECTED" -eq 1 ]; then 
        printf "║ ${C_GRAY}%-15s${C_RESET} : ${C_CYAN}%-45s${C_RESET} ║\n" "Версия Бота" "$BOT_VERSION"
    fi
    if [[ "$WEB_SERVER" != "Не определён" ]]; then 
        printf "║ ${C_GRAY}%-15s${C_RESET} : ${C_CYAN}%-45s${C_RESET} ║\n" "Веб-сервер" "$WEB_SERVER"
    fi
    printf "║ ${C_GRAY}%-15s${C_RESET} : %-54s ║\n" "Сетевой тюнинг" "$cc_status"
    printf "║ ${C_GRAY}%-15s${C_RESET} : %-54s ║\n" "Статус IPv6" "$ipv6_status"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo "Чё делать будем, босс?"
    echo ""
}

show_menu() {
    while true; do
        scan_server_state
        display_header
        echo "   [1] Управление «Форсажем» (BBR+CAKE)"
        echo "   [2] Управление IPv6"
        echo "   [3] Посмотреть журнал «Форсажа»"
        if [ "$BOT_DETECTED" -eq 1 ]; then
            echo "   [4] Посмотреть логи Бота 🤖"
        fi
        if [[ "$SERVER_TYPE" == "Панель" ]]; then
            echo "   [5] Посмотреть логи Панели 📊"
        elif [[ "$SERVER_TYPE" == "Нода" ]]; then
            echo "   [5] Посмотреть логи Ноды 📊"
        fi
        echo -e "   [6] Безопасность сервера ${C_YELLOW}(В разработке 🚧)${C_RESET}"
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
            echo -e "   [u] ${C_YELLOW}ОБНОВИТЬ РЕШАЛУ${C_RESET}"
        fi
        echo ""
        echo -e "   [d] ${C_RED}Снести Решалу нахуй (Удаление)${C_RESET}"
        echo "   [q] Свалить (Выход)"
        echo "------------------------------------------------------"
        read -r -p "Твой выбор, босс: " choice
        case $choice in
            1) apply_bbr; wait_for_enter;;
            2) ipv6_menu;;
            3) view_logs_realtime "$LOGFILE" "Форсажа";;
            4) if [ "$BOT_DETECTED" -eq 1 ]; then view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота"; else echo "Нет такой кнопки."; sleep 2; fi;;
            5) if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE"; else echo "Нет такой кнопки."; sleep 2; fi;;
            6) security_placeholder; wait_for_enter;;
            [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой?"; sleep 2; fi;;
            [dD]) uninstall_script;;
            [qQ]) echo "Был рад помочь. Не обосрись. 🥃"; break;;
            *) echo "Ты прикалываешься?"; sleep 2;;
        esac
    done
}

# --- ГЛАВНЫЙ МОЗГ ---
if [[ "${1:-}" == "install" ]]; then
    install_script "${2:-}"
else
    if [[ $EUID -ne 0 ]]; then 
        if [ "$0" != "$INSTALL_PATH" ]; then
             echo -e "${C_RED}❌ Запускать с 'sudo'.${C_RESET} Используй: ${C_YELLOW}sudo ./$0 install${C_RESET}";
        else
             echo -e "${C_RED}❌ Только для рута. Используй: ${C_YELLOW}sudo reshala${C_RESET}";
        fi
        exit 1;
    fi
    trap - INT TERM EXIT
    show_menu
fi