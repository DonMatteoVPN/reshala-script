#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v1.9946 - STYLE EDITION       ==
# ============================================================ #
# ==    Переписан базар, добавлен стиль, сохранен функционал. ==
# ============================================================ #

set -uo pipefail

# ============================================================ #
#                  КОНСТАНТЫ И ПЕРЕМЕННЫЕ                      #
# ============================================================ #
readonly VERSION="v1.9946"
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/dev/install_reshala.sh"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala.log"
INSTALL_PATH="/usr/local/bin/reshala"

# --- Цвета ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m';
C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_GRAY='\033[0;90m';

# --- Глобальные переменные ---
SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0;
BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён"; UPDATE_AVAILABLE=0;
LATEST_VERSION=""; UPDATE_CHECK_STATUS="OK";

# ============================================================ #
#                     УТИЛИТАРНЫЕ ФУНКЦИИ                      #
# ============================================================ #
run_cmd() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# Логирование
log() { 
    if [ ! -f "$LOGFILE" ]; then 
        run_cmd touch "$LOGFILE"
        run_cmd chmod 666 "$LOGFILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | run_cmd tee -a "$LOGFILE" > /dev/null
}

wait_for_enter() { read -p $'\nЖми Enter, погнали дальше...'; }
save_path() { local key="$1"; local value="$2"; touch "$CONFIG_FILE"; sed -i "/^$key=/d" "$CONFIG_FILE"; echo "$key=\"$value\"" >> "$CONFIG_FILE"; }
load_path() { local key="$1"; [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" &>/dev/null; eval echo "\${$key:-}"; }
get_net_status() { local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a"); local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a"); if [ -z "$qdisc" ] || [ "$qdisc" = "pfifo_fast" ]; then qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n 1) || qdisc="n/a"; fi; echo "$cc|$qdisc"; }

# ============================================================ #
#                 УСТАНОВКА И ОБНОВЛЕНИЕ СКРИПТА               #
# ============================================================ #
install_script() {
    if [[ $EUID -ne 0 ]]; then printf "%b\n" "${C_RED}❌ Эй, только через 'sudo'. Я без прав не работаю.${C_RESET}"; exit 1; fi
    printf "%b\n" "${C_CYAN}🚀 Залетаю в систему (версия ${VERSION})...${C_RESET}"; local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    if ! wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL"; then printf "%b\n" "${C_RED}❌ Не могу достучаться до сервера. Интернет проверь, а?${C_RESET}"; exit 1; fi
    run_cmd cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && run_cmd chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"
    if ! grep -q "alias reshala='sudo reshala'" /root/.bashrc 2>/dev/null; then echo "alias reshala='sudo reshala'" | run_cmd tee -a /root/.bashrc >/dev/null; fi
    log "Скрипт прописался в системе (версия ${VERSION})."
    printf "\n%b\n\n" "${C_GREEN}✅ Всё ровно. Решала на базе.${C_RESET}"; if [[ $(id -u) -eq 0 ]]; then printf "   %b: %b\n" "${C_BOLD}Чтобы позвать меня, пиши" "${C_YELLOW}reshala${C_RESET}"; else printf "   %b: %b\n" "${C_BOLD}Чтобы позвать меня, пиши" "${C_YELLOW}sudo reshala${C_RESET}"; fi
    printf "   %b\n" "${C_RED}⚠️ СЛЫШЬ: Перезайди на сервер, чтобы команда заработала!${C_RESET}"; if [[ "${1:-}" != "update" ]]; then printf "   %s\n" "Установочный файл ('$0') можешь удалять, он больше не нужен."; fi
}
check_for_updates() {
    UPDATE_AVAILABLE=0; LATEST_VERSION=""; UPDATE_CHECK_STATUS="OK"; local max_attempts=3; local attempt=1; local response_body=""; local curl_exit_code=0; local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"; 
    while [ $attempt -le $max_attempts ]; do
        response_body=$(curl --no-progress-meter -s -4 -L --connect-timeout 7 --max-time 15 --retry 2 --retry-delay 3 "$url_with_buster" 2> >(sed 's/^/curl-error: /' >> "$LOGFILE")); curl_exit_code=$?
        if [ $curl_exit_code -eq 0 ] && [ -n "$response_body" ]; then
            LATEST_VERSION=$(echo "$response_body" | grep -m 1 'readonly VERSION' | cut -d'"' -f2)
            if [ -n "$LATEST_VERSION" ]; then
                local local_ver_num; local_ver_num=$(echo "$VERSION" | sed 's/[^0-9.]*//g'); local remote_ver_num; remote_ver_num=$(echo "$LATEST_VERSION" | sed 's/[^0-9.]*//g')
                if [[ "$local_ver_num" != "$remote_ver_num" ]]; then local highest_ver_num; highest_ver_num=$(printf '%s\n%s' "$local_ver_num" "$remote_ver_num" | sort -V | tail -n1); if [[ "$highest_ver_num" == "$remote_ver_num" ]]; then UPDATE_AVAILABLE=1; fi; fi; return 0
            else log "Не смог узнать версию. Ладно, проехали."; fi
        else if [ $attempt -lt $max_attempts ]; then sleep 3; fi; fi; attempt=$((attempt + 1))
    done; UPDATE_CHECK_STATUS="ERROR"; return 1
}
run_update() {
    read -p "   Вышла версия $LATEST_VERSION. Будем обновляться или на старье сидим? (y/n): " confirm_update
    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then printf "%b\n" "${C_YELLOW}🤷‍♂️ Хозяин - барин. Сиди на старой.${C_RESET}"; wait_for_enter; return; fi
    printf "%b\n" "${C_CYAN}🔄 Тяну свежак...${C_RESET}"; local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp); local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
    if ! wget -4 --timeout=20 --tries=3 --retry-connrefused -q -O "$TEMP_SCRIPT" "$url_with_buster"; then printf "%b\n" "${C_RED}❌ Что-то пошло не так. Скачать не вышло. Логи чекни.${C_RESET}"; log "wget облажался с обновлением."; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; fi
    local downloaded_version; downloaded_version=$(grep -m 1 'readonly VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)
    if [ ! -s "$TEMP_SCRIPT" ] || ! bash -n "$TEMP_SCRIPT" 2>/dev/null || [ "$downloaded_version" != "$LATEST_VERSION" ]; then printf "%b\n" "${C_RED}❌ Скачалась какая-то дичь. Отменяю.${C_RESET}"; log "Файл обновления битый."; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; fi
    echo "   Меняю старое на новое..."; run_cmd cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && run_cmd chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"; 
    log "✅ Обновился с $VERSION до $LATEST_VERSION."
    printf "${C_GREEN}✅ Готово. Теперь ты на версии %s. Кайф.${C_RESET}\n" "$LATEST_VERSION"; echo "   Перезагружаюсь, чтобы мозги встали на место..."; sleep 2; exec "$INSTALL_PATH"
}

# ============================================================ #
#                 СБОР ИНФОРМАЦИИ О СИСТЕМЕ                    #
# ============================================================ #
get_docker_version() { local container_name="$1"; local version=""; version=$(run_cmd docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$container_name" 2>/dev/null); if [ -n "$version" ]; then echo "$version"; return; fi; version=$(run_cmd docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null | grep -E '^(APP_VERSION|VERSION)=' | head -n 1 | cut -d'=' -f2); if [ -n "$version" ]; then echo "$version"; return; fi; if run_cmd docker exec "$container_name" test -f /app/package.json 2>/dev/null; then version=$(run_cmd docker exec "$container_name" cat /app/package.json 2>/dev/null | jq -r .version 2>/dev/null); if [ -n "$version" ] && [ "$version" != "null" ]; then echo "$version"; return; fi; fi; if run_cmd docker exec "$container_name" test -f /app/VERSION 2>/dev/null; then version=$(run_cmd docker exec "$container_name" cat /app/VERSION 2>/dev/null | tr -d '\n\r'); if [ -n "$version" ]; then echo "$version"; return; fi; fi; local image_tag; image_tag=$(run_cmd docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2); if [ -n "$image_tag" ] && [ "$image_tag" != "latest" ]; then echo "$image_tag"; return; fi; local image_id; image_id=$(run_cmd docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2); echo "latest (образ: ${image_id:0:7})"; }
scan_server_state() { SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён"; local panel_node_container=""; if run_cmd docker ps --format '{{.Names}}' | grep -q "^remnawave$"; then SERVER_TYPE="Панель"; panel_node_container="remnawave"; elif run_cmd docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then SERVER_TYPE="Нода"; panel_node_container="remnanode"; fi; if [ -n "$panel_node_container" ]; then PANEL_NODE_PATH=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$panel_node_container" 2>/dev/null); PANEL_NODE_VERSION=$(get_docker_version "$panel_node_container"); fi; local bot_container_name="remnawave_bot"; if run_cmd docker ps --format '{{.Names}}' | grep -q "^${bot_container_name}$"; then BOT_DETECTED=1; local bot_compose_path; bot_compose_path=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$bot_container_name" 2>/dev/null || true); if [ -n "$bot_compose_path" ]; then BOT_PATH=$(dirname "$bot_compose_path"); if [ -f "$BOT_PATH/VERSION" ]; then BOT_VERSION=$(cat "$BOT_PATH/VERSION"); else BOT_VERSION=$(get_docker_version "$bot_container_name"); fi; else BOT_VERSION=$(get_docker_version "$bot_container_name"); fi; fi; if run_cmd docker ps --format '{{.Names}}' | grep -q "remnawave-nginx"; then local nginx_version; nginx_version=$(run_cmd docker exec remnawave-nginx nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"); WEB_SERVER="Nginx $nginx_version (в Docker)"; elif run_cmd docker ps --format '{{.Names}}' | grep -q "caddy"; then local caddy_version; caddy_version=$(run_cmd docker exec caddy caddy version 2>/dev/null | cut -d' ' -f1 || echo "unknown"); WEB_SERVER="Caddy $caddy_version (в Docker)"; elif ss -tlpn | grep -q -E 'nginx|caddy|apache2|httpd'; then if command -v nginx &> /dev/null; then local nginx_version; nginx_version=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"); WEB_SERVER="Nginx $nginx_version (на хосте)"; else WEB_SERVER=$(ss -tlpn | grep -E 'nginx|caddy|apache2|httpd' | head -n 1 | sed -n 's/.*users:(("\([^"]*\)".*))/\2/p'); fi; fi; }
get_cpu_info() { local model; model=$(lscpu | grep "Model name" | sed 's/.*Model name:[[:space:]]*//' | sed 's/ @.*//'); echo "$model"; }
get_cpu_load() { local cores; cores=$(nproc); local load; load=$(uptime | awk -F'load average: ' '{print $2}' | cut -d, -f1); echo "$load / $cores ядер"; }
get_ram_info() { free -m | grep Mem | awk '{printf "%.1f/%.1f GB", $3/1024, $2/1024}'; }
get_disk_info() { local root_device; root_device=$(df / | awk 'NR==2 {print $1}'); local main_disk; main_disk=$(lsblk -no pkname "$root_device" 2>/dev/null || basename "$root_device" | sed 's/[0-9]*$//'); local disk_type="HDD"; if [ -f "/sys/block/$main_disk/queue/rotational" ]; then if [ "$(cat "/sys/block/$main_disk/queue/rotational")" -eq 0 ]; then disk_type="SSD"; fi; elif [[ "$main_disk" == *"nvme"* ]]; then disk_type="SSD"; fi; local usage; usage=$(df -h / | awk 'NR==2 {print $3 "/" $2}'); echo "$disk_type ($usage)"; }
get_hoster_info() { curl -s --connect-timeout 5 ipinfo.io/org || echo "Не определён"; }

# ============================================================ #
#                       ОСНОВНЫЕ МОДУЛИ                        #
# ============================================================ #
apply_bbr() { log "🚀 ВКЛЮЧАЮ ТУРБО (BBR/CAKE)..."; local net_status; net_status=$(get_net_status); local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1); local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2); local cake_available; cake_available=$(modprobe sch_cake &>/dev/null && echo "true" || echo "false"); echo "--- ДИАГНОСТИКА ДВИГАТЕЛЯ ---"; echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"; echo "-----------------------------"; if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then printf "%b\n" "${C_GREEN}✅ У тебя и так всё на максимуме (BBR+CAKE). Не мешай машине работать.${C_RESET}"; log "Проверка «Форсаж»: Максимум."; return; fi; if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "fq" && "$cake_available" == "true" ]]; then printf "%b\n" "${C_YELLOW}⚠️ Неплохо (BBR+FQ), но можно круче. CAKE доступен.${C_RESET}"; read -p "   Врубаем CAKE на полную? (y/n): " upgrade_confirm; if [[ "$upgrade_confirm" != "y" && "$upgrade_confirm" != "Y" ]]; then echo "Ок, едем как есть."; log "Отказ от апгрейда до CAKE."; return; fi; echo "Принял. Делаем красиво."; elif [[ "$current_cc" != "bbr" && "$current_cc" != "bbr2" ]]; then echo "Ездишь на стоке? Не порядок. Ща исправим."; fi; local available_cc; available_cc=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}'); local preferred_cc="bbr"; if [[ "$available_cc" == *"bbr2"* ]]; then preferred_cc="bbr2"; fi; local preferred_qdisc="fq"; if [[ "$cake_available" == "true" ]]; then preferred_qdisc="cake"; else log "⚠️ 'cake' нет, ставлю 'fq'."; modprobe sch_fq &>/dev/null; fi; local tcp_fastopen_val=0; [[ $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0) -ge 1 ]] && tcp_fastopen_val=3; local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"; log "🧹 Выкидываю старый хлам..."; run_cmd rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf; if [ -f /etc/sysctl.conf.bak ]; then run_cmd rm /etc/sysctl.conf.bak; fi; run_cmd sed -i.bak -E 's/^[[:space:]]*(net.core.default_qdisc|net.ipv4.tcp_congestion_control)/#&/' /etc/sysctl.conf; log "✍️  Пишу новые настройки..."; echo "# === КОНФИГ «ФОРСАЖ» ОТ РЕШАЛЫ — НЕ ТРОГАТЬ ===
net.ipv4.tcp_congestion_control = $preferred_cc
net.core.default_qdisc = $preferred_qdisc
net.ipv4.tcp_fastopen = $tcp_fastopen_val
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216" | run_cmd tee "$CONFIG_SYSCTL" > /dev/null; log "🔥 Применяю..."; run_cmd sysctl -p "$CONFIG_SYSCTL" >/dev/null; echo ""; echo "--- ПРОВЕРКА ---"; echo "Алгоритм: $(sysctl -n net.ipv4.tcp_congestion_control)"; echo "Планировщик: $(sysctl -n net.core.default_qdisc)"; echo "----------------"; printf "%b\n" "${C_GREEN}✅ Тачка теперь — ракета. (CC: $preferred_cc, QDisc: $preferred_qdisc)${C_RESET}"; log "BBR+CAKE успешно применены."; }

check_ipv6_status() { if [ ! -d "/proc/sys/net/ipv6" ]; then printf "%b" "${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"; elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then printf "%b" "${C_RED}ОТКЛЮЧЁН${C_RESET}"; else printf "%b" "${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi; }
disable_ipv6() { if [ ! -d "/proc/sys/net/ipv6" ]; then printf "%b\n" "❌ ${C_YELLOW}Тут нечего отключать. Провайдер уже всё сделал за тебя.${C_RESET}"; return; fi; if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo "⚠️ IPv6 уже вырублен."; return; fi; echo "🔪 Вырубаю IPv6... Меньше дырок - крепче сон."; run_cmd tee /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ОТКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOL
    run_cmd sysctl -p /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null; log "-> IPv6 отключен."; printf "%b\n" "${C_GREEN}✅ Готово. IPv6 больше не мешает.${C_RESET}"; }
enable_ipv6() { if [ ! -d "/proc/sys/net/ipv6" ]; then printf "%b\n" "❌ ${C_YELLOW}Не могу включить то, чего нет физически.${C_RESET}"; return; fi; if [ ! -f /etc/sysctl.d/98-reshala-disable-ipv6.conf ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 0 ]; then echo "✅ IPv6 и так работает."; return; fi; echo "💉 Возвращаю IPv6 к жизни..."; run_cmd rm -f /etc/sysctl.d/98-reshala-disable-ipv6.conf; run_cmd tee /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ВКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOL
    run_cmd sysctl -p /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null; run_cmd rm -f /etc/sysctl.d/98-reshala-enable-ipv6.conf; log "-> IPv6 включен."; printf "%b\n" "${C_GREEN}✅ IPv6 снова в строю.${C_RESET}"; }

ipv6_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Назад в меню...${C_RESET}"; sleep 1; return' INT

    while true; do
        clear; echo "--- УПРАВЛЕНИЕ IPv6 ---"; printf "Статус сейчас: %b\n" "$(check_ipv6_status)"; echo "-----------------------"; echo "   1. Отключить (Если глючит сеть)"; echo "   2. Включить (Вернуть как было)"; echo "   b. Назад"; 
        read -r -p "Выбирай: " choice || continue
        case $choice in 
            1) disable_ipv6; wait_for_enter;; 
            2) enable_ipv6; wait_for_enter;; 
            [bB]) break;; 
            *) echo "1, 2 или 'b'. Не тупи."; sleep 2;; 
        esac
    done

    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

view_logs_realtime() { 
    local log_path="$1"; local log_name="$2"; 
    
    if [ ! -f "$log_path" ]; then 
        echo "[*] Журнала нет. Создаю новый: $log_path"
        run_cmd touch "$log_path"
        run_cmd chmod 666 "$log_path"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] - Журнал создан." | run_cmd tee -a "$log_path" > /dev/null
    fi
    
    echo "[*] Читаем журнал '$log_name'... (Жми CTRL+C, чтобы выйти)"
    
    local original_int_handler=$(trap -p INT)
    trap "printf '\n%b\n' '${C_GREEN}✅ Всё, хватит чтения.${C_RESET}'; sleep 1;" INT
    
    (run_cmd tail -f -n 50 "$log_path" | awk -F ' - ' -v C_YELLOW="$C_YELLOW" -v C_RESET="$C_RESET" '{print C_YELLOW $1 C_RESET "  " $2}') || true
    
    if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi
    return 0
}

view_docker_logs() { local service_path="$1"; local service_name="$2"; if [ -z "$service_path" ] || [ ! -f "$service_path" ]; then printf "%b\n" "❌ ${C_RED}Путь кривой.${C_RESET}"; sleep 2; return; fi; echo "[*] Смотрим логи '$service_name'... (CTRL+C для выхода)"; local original_int_handler=$(trap -p INT); trap "printf '\n%b\n' '${C_GREEN}✅ Выходим...${C_RESET}'; sleep 1;" INT; (cd "$(dirname "$service_path")" && run_cmd docker compose logs -f) || true; if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi; return 0; }
uninstall_script() { printf "%b\n" "${C_RED}Решил избавиться от Решалы?${C_RESET}"; read -p "Снесу всё: скрипт, конфиги, алиасы. Точно? (y/n): " confirm; if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "Правильно, не горячись."; wait_for_enter; return; fi; echo "Бывай, босс. Самоликвидация..."; if [ -f "$INSTALL_PATH" ]; then run_cmd rm -f "$INSTALL_PATH"; echo "✅ Файл скрипта удалён."; log "-> Скрипт удалён."; fi; if [ -f "/root/.bashrc" ]; then run_cmd sed -i "/alias reshala='sudo reshala'/d" /root/.bashrc; echo "✅ Алиас стёрт."; log "-> Алиас удалён."; fi; if [ -f "$CONFIG_FILE" ]; then rm -f "$CONFIG_FILE"; echo "✅ Конфиг удалён."; log "-> Конфиг удалён."; fi; if [ -f "$LOGFILE" ]; then run_cmd rm -f "$LOGFILE"; echo "✅ Журнал в топке."; fi; printf "%b\n" "${C_GREEN}✅ Всё чисто. Меня здесь не было.${C_RESET}"; echo "   Перезайди в терминал, чтобы забыть меня окончательно."; exit 0; }

# ============================================================ #
#                       МОДУЛЬ БЕЗОПАСНОСТИ                      #
# ============================================================ #
_ensure_package_installed() {
    local package_name="$1"
    if ! command -v "$package_name" &> /dev/null; then
        printf "%b\n" "${C_YELLOW}Нет утилиты '${package_name}'. Ща поставлю...${C_RESET}"
        if [ -f /etc/debian_version ]; then
            run_cmd apt-get update >/dev/null
            run_cmd apt-get install -y "$package_name"
        elif [ -f /etc/redhat-release ]; then
            run_cmd yum install -y "$package_name"
        else
            printf "%b\n" "${C_RED}Не могу сам поставить '${package_name}'. Поставь руками и возвращайся.${C_RESET}"
            return 1
        fi
    fi
    return 0
}
_create_servers_file_template() {
    local file_path="$1"
    cat << 'EOL' > "$file_path"
# --- СПИСОК СЕРВЕРОВ ДЛЯ SSH-КЛЮЧЕЙ ---
#
# --- ПРИМЕРЫ ---
#
# 1. Просто IP (пароль спросит сам)
# root@11.22.33.44
#
# 2. Нестандартный порт
# root@11.22.33.44:2222
#
# 3. Сразу с паролем (чтобы само залетело)
# user@myserver.com MyPassword123
#
# --- СЮДА ПИШИ СВОИ СЕРВЕРЫ ---

EOL
}
_add_key_locally() {
    local pubkey="$1"
    local auth_keys_file="/root/.ssh/authorized_keys"
    printf "\n%b\n" "${C_CYAN}--> Кидаю ключ на ЭТОТ сервер (localhost)...${C_RESET}"
    
    mkdir -p /root/.ssh
    touch "$auth_keys_file"
    
    if grep -q -F "$pubkey" "$auth_keys_file"; then
        printf "    %b\n" "${C_YELLOW}⚠️ Ключ уже тут есть. Пропускаю.${C_RESET}"
    else
        echo "$pubkey" >> "$auth_keys_file"
        printf "    %b\n" "${C_GREEN}✅ Готово! Ключ добавлен.${C_RESET}"
        log "Добавлен SSH-ключ локально."
    fi
    
    chmod 700 /root/.ssh
    chmod 600 "$auth_keys_file"
}

_ssh_add_keys() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_RED}❌ Отмена. Уходим.${C_RESET}"; sleep 1; return 1' INT

    clear; printf "%b\n" "${C_CYAN}--- РАССЫЛКА SSH-КЛЮЧЕЙ ---${C_RESET}"; printf "%s\n" "Помогу раскидать твой ключ по всем серверам, чтобы пароли не вводить.";
    
    printf "\n%b\n" "${C_BOLD}[ ШАГ 1: Где взять ключ? ]${C_RESET}"; printf "%b\n" "Слушай внимательно. Это надо делать ${C_YELLOW}У СЕБЯ НА КОМПЕ${C_RESET}, а не здесь."; printf "\n%b\n" "${C_CYAN}--- Если у тебя Windows ---${C_RESET}"; printf "%s\n" "1. Открой PowerShell."; printf "%s\n" "2. Введи: ${C_GREEN}ssh-keygen -t ed25519${C_RESET} (жми Enter на всё)"; printf "%b\n" "3. Покажи ключ командой: ${C_GREEN}type %USERPROFILE%\\.ssh\\id_ed25519.pub${C_RESET}"; printf "\n%b\n" "${C_CYAN}--- Если Linux / Mac ---${C_RESET}"; printf "%s\n" "1. В терминале: ${C_GREEN}ssh-keygen -t ed25519${C_RESET}"; printf "%b\n" "2. Покажи ключ: ${C_GREEN}cat ~/.ssh/id_ed25519.pub${C_RESET}"; printf "\n%s\n" "Копируй ту строку, что начинается на 'ssh-ed25519...'.";
    
    while true; do
        read -p $'\nСкопировал ключ? Готов продолжать? (y/n): ' confirm_key || return 1
        case "$confirm_key" in
            [yY]) break ;;
            [nN]) printf "\n%b\n" "${C_RED}Ок, приходи когда будешь готов.${C_RESET}"; sleep 2; return ;;
            *) printf "\n%b\n" "${C_RED}y (да) или n (нет). Сложно?${C_RESET}" ;;
        esac
    done
    
    clear; printf "%b\n" "${C_BOLD}[ ШАГ 2: Давай ключ сюда ]${C_RESET}"; read -p "Вставь свой публичный ключ (ssh-ed25519...): " PUBKEY || return 1; if ! [[ "$PUBKEY" =~ ^ssh-(rsa|dss|ed25519|ecdsa) ]]; then printf "\n%b\n" "${C_RED}❌ Это не похоже на ключ. Попробуй еще раз.${C_RESET}"; return; fi;
    
    local SERVERS_FILE_PATH; SERVERS_FILE_PATH="$(pwd)/servers.txt"
    clear; printf "%b\n" "${C_BOLD}[ ШАГ 3: Куда кидать? ]${C_RESET}"
    if [ -f "$SERVERS_FILE_PATH" ]; then
        printf "%b\n" "Нашел список серверов: ${C_YELLOW}${SERVERS_FILE_PATH}${C_RESET}"
        read -p "Что с ним делаем? (1-Редактировать, 2-Использовать, 3-Удалить и новый): " choice || return 1
        case $choice in
            1) _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return ;;
            2) printf "%b\n" "Ок, работаем по списку..." ;;
            3) rm -f "$SERVERS_FILE_PATH"; _create_servers_file_template "$SERVERS_FILE_PATH"; _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return ;;
            *) printf "\n%b\n" "${C_RED}Отмена.${C_RESET}"; return ;;
        esac
    else
        printf "%b\n" "Списка нет. Создаю новый."
        _create_servers_file_template "$SERVERS_FILE_PATH"
        read -p "Жми Enter, открою редактор. Впиши туда IP серверов..."
        _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return
    fi
    
    if ! grep -q -E '[^[:space:]]' "$SERVERS_FILE_PATH" || ! grep -v -E '^\s*#|^\s*$' "$SERVERS_FILE_PATH" | read -r; then printf "\n%b\n" "${C_RED}❌ Файл пустой. Так дело не пойдет.${C_RESET}"; return; fi

    clear; printf "%b\n" "${C_BOLD}[ ШАГ 4: Погнали ]${C_RESET}"; printf "%s\n" "Начинаю обход серверов..."; _ensure_package_installed "sshpass" || return; wait_for_enter;
    local TEMP_KEY_BASE; TEMP_KEY_BASE=$(mktemp); local TEMP_KEY_FILE="${TEMP_KEY_BASE}.pub"; echo "$PUBKEY" > "$TEMP_KEY_FILE"
    
    while read -r -a parts; do
        [[ -z "${parts[0]}" ]] || [[ "${parts[0]}" =~ ^# ]] && continue
        local host_port_part="${parts[0]}"
        local password="${parts[*]:1}"
        
        local host="${host_port_part%:*}"
        local port="${host_port_part##*:}"
        [[ "$host" == "$port" ]] && port=""

        if [[ "$host" == "root@localhost" || "$host" == "root@127.0.0.1" ]]; then
            _add_key_locally "$PUBKEY"
            continue
        fi

        printf "\n%b\n" "${C_CYAN}--> Стучусь на $host_port_part...${C_RESET}"
        local port_arg=""; if [ -n "$port" ]; then port_arg="-p $port"; fi
        
        if [ -n "$password" ]; then
            printf "%b\n" "${C_GRAY}    (пароль взял из файла)${C_RESET}"
            if ! sshpass -p "$password" ssh-copy-id -i "$TEMP_KEY_BASE" $port_arg -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host"; then
                printf "    %b\n" "${C_RED}❌ Не пустили. Пароль не подошел?${C_RESET}"
                log "Ошибка ключа на $host (sshpass)."
            else
                printf "    %b\n" "${C_GREEN}✅ Залетело!${C_RESET}"
                log "Добавлен SSH-ключ на $host."
            fi
        else
            printf "%b\n" "${C_GRAY}    (введи пароль руками)${C_RESET}"
            if ! ssh-copy-id -i "$TEMP_KEY_BASE" $port_arg -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host"; then
                printf "    %b\n" "${C_RED}❌ Ошибка. Не смог подключиться.${C_RESET}"
                log "Ошибка ключа на $host (manual)."
            else
                printf "    %b\n" "${C_GREEN}✅ Залетело!${C_RESET}"
                log "Добавлен SSH-ключ на $host."
            fi
        fi
    done < <(grep -v -E '^\s*#|^\s*$' "$SERVERS_FILE_PATH")
    rm -f "$TEMP_KEY_BASE" "$TEMP_KEY_FILE"
    
    printf "\n%b\n" "${C_GREEN}🎉 Всё, закончили упражнение.${C_RESET}"
    read -p "Файл со списком серверов удаляем? (y/n): " cleanup_choice
    if [[ "$cleanup_choice" == "y" || "$cleanup_choice" == "Y" ]]; then rm -f "$SERVERS_FILE_PATH"; printf "%b\n" "${C_GREEN}✅ Удалил.${C_RESET}"; fi

    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

security_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Назад...${C_RESET}"; sleep 1; return' INT

    while true; do
        clear; echo "--- БЕЗОПАСНОСТЬ ---"; echo "Инструменты для защиты твоей крепости."; echo "--------------------"; echo "   [1] Раскидать SSH-ключи по серверам 🔑"; echo "   [b] Назад в меню"; echo "--------------------"; 
        read -r -p "Выбор: " choice || continue
        case $choice in
            1) _ssh_add_keys; wait_for_enter;;
            [bB]) break;;
            *) printf "%b\n" "${C_RED}Не туда жмешь.${C_RESET}"; sleep 2;;
        esac
    done

    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

# ============================================================ #
#                   ОБНОВЛЕНИЕ СИСТЕМЫ                         #
# ============================================================ #
system_update_wizard() {
    if ! command -v apt &> /dev/null; then 
        echo "Тут нет 'apt'. Это не Debian/Ubuntu, я пас."
        return
    fi

    clear
    printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    printf "%b\n" "${C_CYAN}║               ПРОКАЧКА СИСТЕМЫ (APT UPDATE)                  ║${C_RESET}"
    printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    printf "%b\n" "${C_BOLD}План работ:${C_RESET}"
    printf "  1. %b\n" "${C_GREEN}apt update${C_RESET}       - Узнаем, что нового"
    printf "  2. %b\n" "${C_GREEN}apt upgrade${C_RESET}      - Накатываем обновы"
    printf "  3. %b\n" "${C_GREEN}apt full-upgrade${C_RESET} - Обновляем всё под чистую"
    printf "  4. %b\n" "${C_GREEN}apt autoremove${C_RESET}   - Выносим мусор"
    printf "  5. %b\n" "${C_GREEN}apt autoclean${C_RESET}    - Чистим кэш"
    echo ""
    
    read -p "Запускаем полную прокачку? (y/n): " confirm_upd
    if [[ "$confirm_upd" == "y" || "$confirm_upd" == "Y" ]]; then
        echo ""
        log "Пошла жара (update system)..."
        printf "%b\n" "${C_YELLOW}🚀 Погнали! Можешь пока кофе попить...${C_RESET}"
        
        run_cmd apt update
        run_cmd apt upgrade -y
        run_cmd apt full-upgrade -y
        run_cmd apt autoremove -y
        run_cmd apt autoclean
        run_cmd apt install -y sudo
        
        save_path "LAST_SYS_UPDATE" "$(date +%Y%m%d)"
        
        printf "\n%b\n" "${C_GREEN}✅ Система блестит как новая.${C_RESET}"
        log "Система обновлена."
        wait_for_enter
    else
        echo "Ок, потом так потом."
        save_path "LAST_SYS_UPDATE" "$(date +%Y%m%d)"
        sleep 1
    fi
}

offer_initial_update() {
    local last_check; last_check=$(load_path "LAST_SYS_UPDATE")
    local today; today=$(date +%Y%m%d)
    
    if [ "$last_check" == "$today" ]; then
        return
    fi
    
    system_update_wizard
}

# ============================================================ #
#                   ГЛАВНОЕ МЕНЮ И ИНФО-ПАНЕЛЬ                 #
# ============================================================ #
display_header() {
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}'); local net_status; net_status=$(get_net_status); local cc; cc=$(echo "$net_status" | cut -d'|' -f1); local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2); local cc_status; if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}МАКСИМУМ (bbr + cake)"; else cc_status="${C_GREEN}АКТИВЕН (bbr + $qdisc)"; fi; else cc_status="${C_YELLOW}СТОК ($cc)"; fi; local ipv6_status; ipv6_status=$(check_ipv6_status); local cpu_info; cpu_info=$(get_cpu_info); local cpu_load; cpu_load=$(get_cpu_load); local ram_info; ram_info=$(get_ram_info); local disk_info; disk_info=$(get_disk_info); local hoster_info; hoster_info=$(get_hoster_info); clear; local max_label_width=11; printf "%b\n" "${C_CYAN}╔═[ ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ]${C_RESET}"; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ РАСКЛАД ПО ЖЕЛЕЗУ ]${C_RESET}"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "IP Адрес" "$ip_addr"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Хостер" "$hoster_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Процессор" "$cpu_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Нагрузка" "$cpu_load"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Память" "$ram_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Диск" "$disk_info"; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ ЧТО УСТАНОВЛЕНО ]${C_RESET}"; if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Софт" "$SERVER_TYPE v$PANEL_NODE_VERSION"; else printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Софт" "$SERVER_TYPE"; fi; if [ "$BOT_DETECTED" -eq 1 ]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Бот" "$BOT_VERSION"; fi; if [[ "$WEB_SERVER" != "Не определён" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Веб" "$WEB_SERVER"; fi; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ НАСТРОЙКИ СЕТИ ]${C_RESET}"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "Тюнинг" "$cc_status"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "IPv6" "$ipv6_status"; printf "%b\n" "${C_CYAN}╚${C_RESET}";
}
show_menu() {
    trap 'printf "\n%b\n" "${C_YELLOW}⚠️  Эй, не убивай меня! Жми [q] для выхода.${C_RESET}"; sleep 1' INT

    while true; do
        scan_server_state
        check_for_updates
        display_header

        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
            printf "\n%b\n" "${C_RED}${C_BOLD}ОБНОВА ПОДКАТИЛА! ОБНОВИСЬ, БЛЯ!${C_RESET}"
        fi

        printf "\n%s\n\n" "Командуй, босс:";
        printf "   [0] %b\n" "🛠️  Прокачать систему (apt update & upgrade)"
        echo "   [1] 🏎️  Настроить «Форсаж» (BBR+CAKE)"
        echo "   [2] 🌐 Разобраться с IPv6"
        echo "   [3] 📜 Глянуть логи (Чё там было?)"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo "   [4] 🤖 Логи Бота"; fi
        if [[ "$SERVER_TYPE" == "Панель" ]]; then echo "   [5] 📊 Логи Панели"; elif [[ "$SERVER_TYPE" == "Нода" ]]; then echo "   [5] 📊 Логи Ноды"; fi
        printf "   [6] %b\n" "🛡️  Ключи и доступы ${C_YELLOW}(SSH)${C_RESET}"

        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
            printf "   [u] %b\n" "${C_YELLOW}${C_BOLD}‼️ОБНОВИТЬ РЕШАЛУ‼️${C_RESET}"
        elif [[ "$UPDATE_CHECK_STATUS" != "OK" ]]; then
            printf "\n%b\n" "${C_RED}⚠️ Ошибка проверки обновлений (см. лог)${C_RESET}"
        fi

        echo ""
        printf "   [d] %b\n" "${C_RED}🗑️  Снести скрипт (Самоликвидация)${C_RESET}"
        echo "   [q] 🚪 Выход"
        echo "------------------------------------------------------"
        read -r -p "Твой выбор: " choice || continue

        log "Выбран пункт меню: $choice"

        case $choice in
            0) system_update_wizard;;
            1) apply_bbr; wait_for_enter;;
            2) ipv6_menu;;
            3) view_logs_realtime "$LOGFILE" "Решалы";;
            4) if [ "$BOT_DETECTED" -eq 1 ]; then view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота"; else echo "Нет такой кнопки."; sleep 2; fi;;
            5) if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE"; else echo "Нет такой кнопки."; sleep 2; fi;;
            6) security_menu;;
            [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой? Нет обновы."; sleep 2; fi;;
            [dD]) uninstall_script;;
            [qQ]) echo "Давай, удачи. 🥃"; break;;
            *) echo "Такой команды нет. Протри глаза."; sleep 2;;
        esac
    done
}

# ============================================================ #
#                       ТОЧКА ВХОДА В СКРИПТ                   #
# ============================================================ #
main() {
    if [ ! -f "$LOGFILE" ]; then 
        run_cmd touch "$LOGFILE"
        run_cmd chmod 666 "$LOGFILE"
    fi
    
    log "Старт скрипта Решала ${VERSION}"

    if [[ "${1:-}" == "install" ]]; then
        install_script "${2:-}"
    else
        if [[ $EUID -ne 0 ]]; then 
            if [ "$0" != "$INSTALL_PATH" ]; then printf "%b\n" "${C_RED}❌ Нужны права root.${C_RESET} Пиши: ${C_YELLOW}sudo ./$0 install${C_RESET}"; else printf "%b\n" "${C_RED}❌ Нужны права root. Пиши: ${C_YELLOW}sudo reshala${C_RESET}"; fi
            exit 1;
        fi
        trap "rm -f /tmp/tmp.*" EXIT
        
        offer_initial_update
        
        show_menu
    fi
}

main "$@"