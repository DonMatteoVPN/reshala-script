#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v0.5 dev - MERGED EDITION    ==
# ============================================================ #
# ==    Объединение финального дизайна и требуемой           ==
# ==    системы обновлений.                                  ==
# ============================================================ #

set -euo pipefail

# --- КОНСТАНТЫ И ПЕРЕМЕННЫЕ ---
readonly VERSION="v0.5 dev"
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

# --- МОДУЛЬ ОБНОВЛЕНИЯ (ИЗ v0.3451) ---
check_for_updates() {
    UPDATE_AVAILABLE=0
    LATEST_VERSION=""
    UPDATE_CHECK_STATUS="OK"
    
    local max_attempts=3
    local attempt=1
    local response_body=""
    local curl_exit_code=0
    
    local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
    
    log "Начинаю проверку обновлений по URL: $url_with_buster"
    
    while [ $attempt -le $max_attempts ]; do
        response_body=$(curl -4 -L --connect-timeout 7 --max-time 15 --retry 2 --retry-delay 3 \
            "$url_with_buster" 2> >(sed 's/^/curl-error: /' >> "$LOGFILE"))
        curl_exit_code=$?
        
        if [ $curl_exit_code -eq 0 ] && [ -n "$response_body" ]; then
            LATEST_VERSION=$(echo "$response_body" | grep -m 1 'readonly VERSION' | cut -d'"' -f2)
            if [ -n "$LATEST_VERSION" ]; then
                log "Удалённая версия: $LATEST_VERSION. Локальная: $VERSION."
                
                local local_ver_num; local_ver_num=$(echo "$VERSION" | sed 's/[^0-9.]*//g')
                local remote_ver_num; remote_ver_num=$(echo "$LATEST_VERSION" | sed 's/[^0-9.]*//g')

                if [[ "$local_ver_num" != "$remote_ver_num" ]]; then
                    local highest_ver_num
                    highest_ver_num=$(printf '%s\n%s' "$local_ver_num" "$remote_ver_num" | sort -V | tail -n1)
                    if [[ "$highest_ver_num" == "$remote_ver_num" ]]; then
                        UPDATE_AVAILABLE=1
                        log "Обнаружена новая версия (числовое сравнение: $remote_ver_num > $local_ver_num)."
                    fi
                fi
                return 0
            else
                log "Попытка $attempt: Ответ получен, но не могу найти строку с версией."
            fi
        else
            log "Попытка $attempt из $max_attempts не удалась (код выхода curl: $curl_exit_code)."
            if [ $attempt -lt $max_attempts ]; then
                sleep 3
            fi
        fi
        
        attempt=$((attempt + 1))
    done

    UPDATE_CHECK_STATUS="ERROR"
    log "Ошибка проверки обновлений после $max_attempts попыток."
    return 1
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
        echo -e "${C_RED}❌ Хуйня какая-то. Не могу скачать обнову. Проверь инет и лог /var/log/reshala_ops.log.${C_RESET}"; 
        log "wget не смог скачать $url_with_buster"
        rm -f "$TEMP_SCRIPT"; wait_for_enter
        return
    fi

    local downloaded_version
    downloaded_version=$(grep -m 1 'readonly VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)
    if [ ! -s "$TEMP_SCRIPT" ] || ! bash -n "$TEMP_SCRIPT" 2>/dev/null || [ "$downloaded_version" != "$LATEST_VERSION" ]; then
        echo -e "${C_RED}❌ Скачалось какое-то дерьмо, а не скрипт. Отбой.${C_RESET}"; 
        log "Скачанный файл обновления не прошел проверку. Ожидалась версия $LATEST_VERSION, в файле $downloaded_version."
        rm -f "$TEMP_SCRIPT"; wait_for_enter
        return
    fi
    
    echo "   Ставлю на место старого..."
    sudo cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && sudo chmod +x "$INSTALL_PATH"
    rm "$TEMP_SCRIPT"

    printf "${C_GREEN}✅ Готово. Теперь у тебя версия %s. Не благодари.${C_RESET}\n" "$LATEST_VERSION"
    echo "   Перезапускаю себя, чтобы мозги встали на место..."
    sleep 2
    exec "$INSTALL_PATH"
}

# --- МОДУЛЬ АВТООПРЕДЕЛЕНИЯ ---
get_docker_version() {
    local container_name="$1"; local version=""
    version=$(sudo docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$container_name" 2>/dev/null); if [ -n "$version" ]; then echo "$version"; return; fi
    version=$(sudo docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null | grep -E '^(APP_VERSION|VERSION)=' | head -n 1 | cut -d'=' -f2); if [ -n "$version" ]; then echo "$version"; return; fi
    if sudo docker exec "$container_name" test -f /app/package.json 2>/dev/null; then version=$(sudo docker exec "$container_name" cat /app/package.json 2>/dev/null | jq -r .version 2>/dev/null); if [ -n "$version" ] && [ "$version" != "null" ]; then echo "$version"; return; fi; fi
    if sudo docker exec "$container_name" test -f /app/VERSION 2>/dev/null; then version=$(sudo docker exec "$container_name" cat /app/VERSION 2>/dev/null | tr -d '\n\r'); if [ -n "$version" ]; then echo "$version"; return; fi; fi
    local image_tag; image_tag=$(sudo docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2); if [ -n "$image_tag" ] && [ "$image_tag" != "latest" ]; then echo "$image_tag"; return; fi
    local image_id; image_id=$(sudo docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2); echo "latest (образ: ${image_id:0:7})"
}
scan_server_state() {
    SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён"
    local panel_node_container=""; if sudo docker ps --format '{{.Names}}' | grep -q "^remnawave$"; then SERVER_TYPE="Панель"; panel_node_container="remnawave"; elif sudo docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then SERVER_TYPE="Нода"; panel_node_container="remnanode"; fi
    if [ -n "$panel_node_container" ]; then PANEL_NODE_PATH=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$panel_node_container" 2>/dev/null); PANEL_NODE_VERSION=$(get_docker_version "$panel_node_container"); fi
    local bot_container_name="remnawave_bot"; if sudo docker ps --format '{{.Names}}' | grep -q "^${bot_container_name}$"; then BOT_DETECTED=1; local bot_compose_path; bot_compose_path=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$bot_container_name" 2>/dev/null || true); if [ -n "$bot_compose_path" ]; then BOT_PATH=$(dirname "$bot_compose_path"); if [ -f "$BOT_PATH/VERSION" ]; then BOT_VERSION=$(cat "$BOT_PATH/VERSION"); else BOT_VERSION=$(get_docker_version "$bot_container_name"); fi; else BOT_VERSION=$(get_docker_version "$bot_container_name"); fi; fi
    if sudo docker ps --format '{{.Names}}' | grep -q "remnawave-nginx"; then local nginx_version; nginx_version=$(sudo docker exec remnawave-nginx nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"); WEB_SERVER="Nginx $nginx_version (в Docker)"; elif sudo docker ps --format '{{.Names}}' | grep -q "caddy"; then local caddy_version; caddy_version=$(sudo docker exec caddy caddy version 2>/dev/null | cut -d' ' -f1 || echo "unknown"); WEB_SERVER="Caddy $caddy_version (в Docker)"; elif ss -tlpn | grep -q -E 'nginx|caddy|apache2|httpd'; then if command -v nginx &> /dev/null; then local nginx_version; nginx_version=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"); WEB_SERVER="Nginx $nginx_version (на хосте)"; else WEB_SERVER=$(ss -tlpn | grep -E 'nginx|caddy|apache2|httpd' | head -n 1 | sed -n 's/.*users:(("\([^"]*\)".*))/\2/p'); fi; fi
}

# --- ФУНКЦИИ ДЛЯ СБОРА ИНФОРМАЦИИ О СЕРВЕРЕ ---
get_cpu_info() {
    local model; model=$(lscpu | grep "Model name" | sed 's/.*Model name:[[:space:]]*//' | sed 's/ @.*//'); echo "$model"
}
get_cpu_load() {
    local cores; cores=$(nproc); local load; load=$(uptime | awk -F'load average: ' '{print $2}' | cut -d, -f1); echo "$load / $cores ядер"
}
get_ram_info() {
    free -m | grep Mem | awk '{printf "%.1f/%.1f GB", $3/1024, $2/1024}'
}
get_disk_info() {
    local root_device; root_device=$(df / | awk 'NR==2 {print $1}'); local main_disk; main_disk=$(lsblk -no pkname "$root_device" 2>/dev/null || basename "$root_device" | sed 's/[0-9]*$//'); local disk_type="HDD"; if [ -f "/sys/block/$main_disk/queue/rotational" ]; then if [ "$(cat "/sys/block/$main_disk/queue/rotational")" -eq 0 ]; then disk_type="SSD"; fi; elif [[ "$main_disk" == *"nvme"* ]]; then disk_type="SSD"; fi; local usage; usage=$(df -h / | awk 'NR==2 {print $3 "/" $2}'); echo "$disk_type ($usage)"
}
get_hoster_info() {
    curl -s --connect-timeout 5 ipinfo.io/org || echo "Не определён"
}

# --- ОСНОВНЫЕ МОДУЛИ СКРИПТА ---
apply_bbr() { :; }
check_ipv6_status() {
    if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"; elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo -e "${C_RED}КАСТРИРОВАН${C_RESET}"; else echo -e "${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi
}
disable_ipv6() { :; }
enable_ipv6() { :; }
ipv6_menu() { :; }
view_logs_realtime() { :; }
view_docker_logs() { :; }
security_placeholder() { :; }
uninstall_script() { :; }

# --- ИНФО-ПАНЕЛЬ И ГЛАВНОЕ МЕНЮ (НОВЫЙ ДИЗАЙН) ---
display_header() {
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}'); local net_status; net_status=$(get_net_status); local cc; cc=$(echo "$net_status" | cut -d'|' -f1); local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2); local cc_status; if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}МАКСИМУМ (bbr + cake)"; else cc_status="${C_GREEN}АКТИВЕН (bbr + $qdisc)"; fi; else cc_status="${C_YELLOW}СТОК ($cc)"; fi; local ipv6_status; ipv6_status=$(check_ipv6_status); local cpu_info; cpu_info=$(get_cpu_info); local cpu_load; cpu_load=$(get_cpu_load); local ram_info; ram_info=$(get_ram_info); local disk_info; disk_info=$(get_disk_info); local hoster_info; hoster_info=$(get_hoster_info)
    clear
    
    local max_label_width=11

    echo -e "${C_CYAN}╔═[ ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ]${C_RESET}"
    
    echo -e "${C_CYAN}║${C_RESET}"
    echo -e "${C_CYAN}╠═[ ИНФО ПО СЕРВЕРУ ]${C_RESET}"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "IP Адрес" "$ip_addr"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Хостер" "$hoster_info"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Процессор" "$cpu_info"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Нагрузка" "$cpu_load"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Оперативка" "$ram_info"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Диск" "$disk_info"
    
    echo -e "${C_CYAN}║${C_RESET}"
    echo -e "${C_CYAN}╠═[ СТАТУС СИСТЕМ ]${C_RESET}"
    if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE v$PANEL_NODE_VERSION"; else printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE"; fi
    if [ "$BOT_DETECTED" -eq 1 ]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Бот" "$BOT_VERSION"; fi
    if [[ "$WEB_SERVER" != "Не определён" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Веб-сервер" "$WEB_SERVER"; fi
    
    echo -e "${C_CYAN}║${C_RESET}"
    echo -e "${C_CYAN}╠═[ СЕТЕВЫЕ НАСТРОЙКИ ]${C_RESET}"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "Тюнинг" "$cc_status"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "IPv6" "$ipv6_status"
    
    echo -e "${C_CYAN}╚${C_RESET}"
}

show_menu() {
    while true; do
        scan_server_state
        display_header
        
        check_for_updates
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then 
            echo -e "\n${C_YELLOW}🔥 Новая версия на подходе: ${LATEST_VERSION}${C_RESET}"
        elif [[ "$UPDATE_CHECK_STATUS" != "OK" ]]; then 
            echo -e "\n${C_RED}⚠️ Ошибка проверки обновлений (см. лог)${C_RESET}"
        fi

        echo -e "\nЧё делать будем, босс?\n"
        echo "   [1] Управление «Форсажем» (BBR+CAKE)"; echo "   [2] Управление IPv6"; echo "   [3] Посмотреть журнал «Форсажа»"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo "   [4] Посмотреть логи Бота 🤖"; fi
        if [[ "$SERVER_TYPE" == "Панель" ]]; then echo "   [5] Посмотреть логи Панели 📊"; elif [[ "$SERVER_TYPE" == "Нода" ]]; then echo "   [5] Посмотреть логи Ноды 📊"; fi
        echo -e "   [6] Безопасность сервера ${C_YELLOW}(В разработке 🚧)${C_RESET}"
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then echo -e "   [u] ${C_YELLOW}ОБНОВИТЬ РЕШАЛУ${C_RESET}"; fi
        echo ""; echo -e "   [d] ${C_RED}Снести Решалу нахуй (Удаление)${C_RESET}"; echo "   [q] Свалить (Выход)"; echo "------------------------------------------------------"; read -r -p "Твой выбор, босс: " choice
        case $choice in
            1) apply_bbr; wait_for_enter;; 2) ipv6_menu;; 3) view_logs_realtime "$LOGFILE" "Форсажа";; 4) if [ "$BOT_DETECTED" -eq 1 ]; then view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота"; else echo "Нет такой кнопки."; sleep 2; fi;; 5) if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE"; else echo "Нет такой кнопки."; sleep 2; fi;; 6) security_placeholder; wait_for_enter;; [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой?"; sleep 2; fi;; [dD]) uninstall_script;; [qQ]) echo "Был рад помочь. Не обосрись. 🥃"; break;; *) echo "Ты прикалываешься?"; sleep 2;;
        esac
    done
}

# --- ГЛАВНЫЙ МОЗГ ---
if [[ "${1:-}" == "install" ]]; then
    install_script "${2:-}"
else
    if [[ $EUID -ne 0 ]]; then 
        if [ "$0" != "$INSTALL_PATH" ]; then echo -e "${C_RED}❌ Запускать с 'sudo'.${C_RESET} Используй: ${C_YELLOW}sudo ./$0 install${C_RESET}"; else echo -e "${C_RED}❌ Только для рута. Используй: ${C_YELLOW}sudo reshala${C_RESET}"; fi
        exit 1;
    fi
    trap - INT TERM EXIT
    show_menu
fi
