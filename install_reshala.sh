#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v2.02 - MODULAR INSTALL     ==
# ============================================================ #
# ==    1. Модульная установка (выбор компонентов).         ==
# ==    2. Ручной ввод всех доменов (без авто-генерации).   ==
# ==    3. Динамическая сборка docker-compose и nginx.      ==
# ==    4. Улучшено уведомление об обновлениях.             ==
# ============================================================ #

set -uo pipefail

# ============================================================ #
#                  КОНСТАНТЫ И ПЕРЕМЕННЫЕ                      #
# ============================================================ #
readonly VERSION="v2.02"
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/dev/install_reshala.sh"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala.log"
INSTALL_PATH="/usr/local/bin/reshala"
REMNA_DIR="/opt/remnawave"

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

log() { 
    if [ ! -f "$LOGFILE" ]; then 
        run_cmd touch "$LOGFILE"
        run_cmd chmod 666 "$LOGFILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | run_cmd tee -a "$LOGFILE" > /dev/null
}

wait_for_enter() { read -p $'\nНажми Enter, чтобы продолжить...'; }
save_path() { local key="$1"; local value="$2"; touch "$CONFIG_FILE"; sed -i "/^$key=/d" "$CONFIG_FILE"; echo "$key=\"$value\"" >> "$CONFIG_FILE"; }
load_path() { local key="$1"; [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" &>/dev/null; eval echo "\${$key:-}"; }
get_net_status() { local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a"); local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a"); if [ -z "$qdisc" ] || [ "$qdisc" = "pfifo_fast" ]; then qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n 1) || qdisc="n/a"; fi; echo "$cc|$qdisc"; }
generate_password() { < /dev/urandom tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }
generate_hex() { openssl rand -hex "${1:-32}"; }

# ============================================================ #
#                 УСТАНОВКА И ОБНОВЛЕНИЕ СКРИПТА               #
# ============================================================ #
install_script() {
    if [[ $EUID -ne 0 ]]; then printf "%b\n" "${C_RED}❌ Эту команду — только с 'sudo'.${C_RESET}"; exit 1; fi
    printf "%b\n" "${C_CYAN}🚀 Интегрирую Решалу ${VERSION} в систему...${C_RESET}"; local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    if ! wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL"; then printf "%b\n" "${C_RED}❌ Не могу скачать последнюю версию. Проверь интернет или ссылку.${C_RESET}"; exit 1; fi
    run_cmd cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && run_cmd chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"
    if ! grep -q "alias reshala='sudo reshala'" /root/.bashrc 2>/dev/null; then echo "alias reshala='sudo reshala'" | run_cmd tee -a /root/.bashrc >/dev/null; fi
    log "Скрипт установлен/переустановлен (версия ${VERSION})."
    printf "\n%b\n\n" "${C_GREEN}✅ Готово. Решала в системе.${C_RESET}"; if [[ $(id -u) -eq 0 ]]; then printf "   %b: %b\n" "${C_BOLD}Команда запуска" "${C_YELLOW}reshala${C_RESET}"; else printf "   %b: %b\n" "${C_BOLD}Команда запуска" "${C_YELLOW}sudo reshala${C_RESET}"; fi
    printf "   %b\n" "${C_RED}⚠️ ВАЖНО: ПЕРЕПОДКЛЮЧИСЬ к серверу, чтобы команда заработала.${C_RESET}"; if [[ "${1:-}" != "update" ]]; then printf "   %s\n" "Установочный файл ('$0') можешь сносить."; fi
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
            else log "Ошибка проверки обновлений: не найдена версия."; fi
        else if [ $attempt -lt $max_attempts ]; then sleep 3; fi; fi; attempt=$((attempt + 1))
    done; UPDATE_CHECK_STATUS="ERROR"; return 1
}
run_update() {
    read -p "   Доступна версия $LATEST_VERSION. Обновляемся, или дальше на старье пердеть будем? (y/n): " confirm_update
    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then printf "%b\n" "${C_YELLOW}🤷‍♂️ Ну и сиди со старьём. Твоё дело.${C_RESET}"; wait_for_enter; return; fi
    printf "%b\n" "${C_CYAN}🔄 Качаю свежак...${C_RESET}"; local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp); local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
    if ! wget -4 --timeout=20 --tries=3 --retry-connrefused -q -O "$TEMP_SCRIPT" "$url_with_buster"; then printf "%b\n" "${C_RED}❌ Хуйня какая-то. Не могу скачать обнову. Проверь инет и лог.${C_RESET}"; log "wget не смог скачать обновление."; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; fi
    local downloaded_version; downloaded_version=$(grep -m 1 'readonly VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)
    if [ ! -s "$TEMP_SCRIPT" ] || ! bash -n "$TEMP_SCRIPT" 2>/dev/null || [ "$downloaded_version" != "$LATEST_VERSION" ]; then printf "%b\n" "${C_RED}❌ Скачалось какое-то дерьмо, а не скрипт. Отбой.${C_RESET}"; log "Ошибка целостности обновления."; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; fi
    echo "   Ставлю на место старого..."; run_cmd cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && run_cmd chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"; 
    log "✅ Скрипт успешно обновлён с версии $VERSION до $LATEST_VERSION."
    printf "${C_GREEN}✅ Готово. Теперь у тебя версия %s. Не благодари.${C_RESET}\n" "$LATEST_VERSION"; echo "   Перезапускаю себя, чтобы мозги встали на место..."; sleep 2; exec "$INSTALL_PATH"
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
apply_bbr() { log "🚀 ЗАПУСК ТУРБОНАДДУВА (BBR/CAKE)..."; local net_status; net_status=$(get_net_status); local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1); local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2); local cake_available; cake_available=$(modprobe sch_cake &>/dev/null && echo "true" || echo "false"); echo "--- ДИАГНОСТИКА ТВОЕГО ДВИГАТЕЛЯ ---"; echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"; echo "------------------------------------"; if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then printf "%b\n" "${C_GREEN}✅ Ты уже на максимальном форсаже (BBR+CAKE). Не мешай машине работать.${C_RESET}"; log "Проверка «Форсаж»: Максимум."; return; fi; if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "fq" && "$cake_available" == "true" ]]; then printf "%b\n" "${C_YELLOW}⚠️ У тебя неплохо (BBR+FQ), но можно лучше. CAKE доступен.${C_RESET}"; read -p "   Хочешь проапгрейдиться до CAKE? Это топчик. (y/n): " upgrade_confirm; if [[ "$upgrade_confirm" != "y" && "$upgrade_confirm" != "Y" ]]; then echo "Как скажешь. Остаёмся на FQ."; log "Отказ от апгрейда до CAKE."; return; fi; echo "Красава. Делаем как надо."; elif [[ "$current_cc" != "bbr" && "$current_cc" != "bbr2" ]]; then echo "Хм, ездишь на стоке. Пора залить ракетное топливо."; fi; local available_cc; available_cc=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}'); local preferred_cc="bbr"; if [[ "$available_cc" == *"bbr2"* ]]; then preferred_cc="bbr2"; fi; local preferred_qdisc="fq"; if [[ "$cake_available" == "true" ]]; then preferred_qdisc="cake"; else log "⚠️ 'cake' не найден, ставлю 'fq'."; modprobe sch_fq &>/dev/null; fi; local tcp_fastopen_val=0; [[ $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0) -ge 1 ]] && tcp_fastopen_val=3; local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"; log "🧹 Чищу старое говно..."; run_cmd rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf; if [ -f /etc/sysctl.conf.bak ]; then run_cmd rm /etc/sysctl.conf.bak; fi; run_cmd sed -i.bak -E 's/^[[:space:]]*(net.core.default_qdisc|net.ipv4.tcp_congestion_control)/#&/' /etc/sysctl.conf; log "✍️  Устанавливаю новые, пиздатые настройки..."; echo "# === КОНФИГ «ФОРСАЖ» ОТ РЕШАЛЫ — НЕ ТРОГАТЬ ===
net.ipv4.tcp_congestion_control = $preferred_cc
net.core.default_qdisc = $preferred_qdisc
net.ipv4.tcp_fastopen = $tcp_fastopen_val
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216" | run_cmd tee "$CONFIG_SYSCTL" > /dev/null; log "🔥 Применяю настройки..."; run_cmd sysctl -p "$CONFIG_SYSCTL" >/dev/null; echo ""; echo "--- КОНТРОЛЬНЫЙ ВЫСТРЕЛ ---"; echo "Новый алгоритм: $(sysctl -n net.ipv4.tcp_congestion_control)"; echo "Новый планировщик: $(sysctl -n net.core.default_qdisc)"; echo "---------------------------"; printf "%b\n" "${C_GREEN}✅ Твоя тачка теперь — ракета. (CC: $preferred_cc, QDisc: $preferred_qdisc)${C_RESET}"; log "BBR+CAKE успешно применены."; }

check_ipv6_status() { if [ ! -d "/proc/sys/net/ipv6" ]; then printf "%b" "${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"; elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then printf "%b" "${C_RED}КАСТРИРОВАН${C_RESET}"; else printf "%b" "${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi; }
disable_ipv6() { if [ ! -d "/proc/sys/net/ipv6" ]; then printf "%b\n" "❌ ${C_YELLOW}Тут нечего отключать. Провайдер уже всё отрезал за тебя.${C_RESET}"; return; fi; if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo "⚠️ IPv6 уже кастрирован."; return; fi; echo "🔪 Кастрирую IPv6... Это не больно. Почти."; run_cmd tee /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ОТКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOL
    run_cmd sysctl -p /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null; log "-> IPv6 кастрирован через sysctl."; printf "%b\n" "${C_GREEN}✅ Готово. Теперь эта тачка ездит только на нормальном топливе.${C_RESET}"; }
enable_ipv6() { if [ ! -d "/proc/sys/net/ipv6" ]; then printf "%b\n" "❌ ${C_YELLOW}Тут нечего включать. Я не могу пришить то, что отрезано с корнем.${C_RESET}"; return; fi; if [ ! -f /etc/sysctl.d/98-reshala-disable-ipv6.conf ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 0 ]; then echo "✅ IPv6 и так работает. Не мешай ему."; return; fi; echo "💉 Возвращаю всё как было... Реанимация IPv6."; run_cmd rm -f /etc/sysctl.d/98-reshala-disable-ipv6.conf; run_cmd tee /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ВКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOL
    run_cmd sysctl -p /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null; run_cmd rm -f /etc/sysctl.d/98-reshala-enable-ipv6.conf; log "-> IPv6 реанимирован."; printf "%b\n" "${C_GREEN}✅ РЕАНИМАЦИЯ ЗАВЕРШЕНА.${C_RESET}"; }

ipv6_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Возвращаюсь в главное меню...${C_RESET}"; sleep 1; return' INT

    while true; do
        clear; echo "--- УПРАВЛЕНИЕ IPv6 ---"; printf "Статус IPv6: %b\n" "$(check_ipv6_status)"; echo "--------------------------"; echo "   1. Кастрировать (Отключить)"; echo "   2. Реанимировать (Включить)"; echo "   b. Назад в главное меню"; 
        read -r -p "Твой выбор: " choice || continue
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
        run_cmd touch "$log_path"
        run_cmd chmod 666 "$log_path"
    fi
    echo "[*] Смотрю журнал '$log_name'... (CTRL+C, чтобы свалить)"
    local original_int_handler=$(trap -p INT)
    trap "printf '\n%b\n' '${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT
    (run_cmd tail -f -n 50 "$log_path" | awk -F ' - ' -v C_YELLOW="$C_YELLOW" -v C_RESET="$C_RESET" '{print C_YELLOW $1 C_RESET "  " $2}') || true
    if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi
    return 0
}

view_docker_logs() { local service_path="$1"; local service_name="$2"; if [ -z "$service_path" ] || [ ! -f "$service_path" ]; then printf "%b\n" "❌ ${C_RED}Путь — хуйня.${C_RESET}"; sleep 2; return; fi; echo "[*] Смотрю потроха '$service_name'... (CTRL+C, чтобы свалить)"; local original_int_handler=$(trap -p INT); trap "printf '\n%b\n' '${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT; (cd "$(dirname "$service_path")" && run_cmd docker compose logs -f) || true; if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi; return 0; }
uninstall_script() { printf "%b\n" "${C_RED}Точно хочешь выгнать Решалу?${C_RESET}"; read -p "Это снесёт скрипт, конфиги и алиасы. (y/n): " confirm; if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "Правильное решение."; wait_for_enter; return; fi; echo "Прощай, босс. Начинаю самоликвидацию..."; if [ -f "$INSTALL_PATH" ]; then run_cmd rm -f "$INSTALL_PATH"; echo "✅ Главный файл снесён."; log "-> Скрипт удалён."; fi; if [ -f "/root/.bashrc" ]; then run_cmd sed -i "/alias reshala='sudo reshala'/d" /root/.bashrc; echo "✅ Алиас выпилен."; log "-> Алиас удалён."; fi; if [ -f "$CONFIG_FILE" ]; then rm -f "$CONFIG_FILE"; echo "✅ Конфиг стёрт."; log "-> Конфиг удалён."; fi; if [ -f "$LOGFILE" ]; then run_cmd rm -f "$LOGFILE"; echo "✅ Журнал сожжён."; fi; printf "%b\n" "${C_GREEN}✅ Самоликвидация завершена.${C_RESET}"; echo "   Переподключись, чтобы алиас 'reshala' сдох."; exit 0; }

# ============================================================ #
#                       МОДУЛЬ БЕЗОПАСНОСТИ                      #
# ============================================================ #
_ensure_package_installed() {
    local package_name="$1"
    if ! command -v "$package_name" &> /dev/null; then
        printf "%b\n" "${C_YELLOW}Утилита '${package_name}' не найдена. Устанавливаю...${C_RESET}"
        if [ -f /etc/debian_version ]; then
            run_cmd apt-get update >/dev/null
            run_cmd apt-get install -y "$package_name"
        elif [ -f /etc/redhat-release ]; then
            run_cmd yum install -y "$package_name"
        else
            printf "%b\n" "${C_RED}Не могу автоматически установить '${package_name}' для твоей ОС. Установи вручную и попробуй снова.${C_RESET}"
            return 1
        fi
    fi
    return 0
}
_create_servers_file_template() {
    local file_path="$1"
    cat << 'EOL' > "$file_path"
# --- СПИСОК СЕРВЕРОВ ДЛЯ ДОБАВЛЕНИЯ SSH-КЛЮЧА ---
# root@11.22.33.44
# root@11.22.33.44:2222
# user@myserver.com MyPassword123
EOL
}
_add_key_locally() {
    local pubkey="$1"
    local auth_keys_file="/root/.ssh/authorized_keys"
    printf "\n%b\n" "${C_CYAN}--> Добавляю ключ на текущий сервер (localhost)...${C_RESET}"
    mkdir -p /root/.ssh
    touch "$auth_keys_file"
    if grep -q -F "$pubkey" "$auth_keys_file"; then
        printf "    %b\n" "${C_YELLOW}⚠️ Ключ уже существует. Пропускаю.${C_RESET}"
    else
        echo "$pubkey" >> "$auth_keys_file"
        printf "    %b\n" "${C_GREEN}✅ Успех! Ключ добавлен локально.${C_RESET}"
        log "Добавлен SSH-ключ локально."
    fi
    chmod 700 /root/.ssh
    chmod 600 "$auth_keys_file"
}

_ssh_add_keys() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_RED}❌ Операция отменена. Возвращаюсь...${C_RESET}"; sleep 1; return 1' INT
    clear; printf "%b\n" "${C_CYAN}--- МАССОВОЕ ДОБАВЛЕНИЕ SSH-КЛЮЧЕЙ ---${C_RESET}";
    printf "\n%b\n" "${C_BOLD}[ ШАГ 1: Подготовь публичный ключ ]${C_RESET}";
    while true; do
        read -p $'\nТы скопировал свой ПУБЛИЧНЫЙ ключ и готов продолжить? (y/n): ' confirm_key || return 1
        case "$confirm_key" in [yY]) break ;; [nN]) return ;; *) ;; esac
    done
    clear; printf "%b\n" "${C_BOLD}[ ШАГ 2: Вставь свой ключ ]${C_RESET}"; read -p "Вставь сюда свой публичный ключ (ssh-ed25519...): " PUBKEY || return 1;
    local SERVERS_FILE_PATH; SERVERS_FILE_PATH="$(pwd)/servers.txt"
    clear; printf "%b\n" "${C_BOLD}[ ШАГ 3: Управление списком серверов ]${C_RESET}"
    if [ -f "$SERVERS_FILE_PATH" ]; then
        read -p "Что делаем? (1-Редактировать, 2-Использовать как есть, 3-Удалить и создать заново): " choice || return 1
        case $choice in 1) _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return ;; 2) ;; 3) rm -f "$SERVERS_FILE_PATH"; _create_servers_file_template "$SERVERS_FILE_PATH"; _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return ;; *) return ;; esac
    else
        _create_servers_file_template "$SERVERS_FILE_PATH"; _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return
    fi
    clear; printf "%b\n" "${C_BOLD}[ ШАГ 4: Установка ключа на серверы ]${C_RESET}"; _ensure_package_installed "sshpass" || return; wait_for_enter;
    local TEMP_KEY_BASE; TEMP_KEY_BASE=$(mktemp); local TEMP_KEY_FILE="${TEMP_KEY_BASE}.pub"; echo "$PUBKEY" > "$TEMP_KEY_FILE"
    while read -r -a parts; do
        [[ -z "${parts[0]}" ]] || [[ "${parts[0]}" =~ ^# ]] && continue
        local host_port_part="${parts[0]}"; local password="${parts[*]:1}"; local host="${host_port_part%:*}"; local port="${host_port_part##*:}"
        [[ "$host" == "$port" ]] && port=""
        if [[ "$host" == "root@localhost" || "$host" == "root@127.0.0.1" ]]; then _add_key_locally "$PUBKEY"; continue; fi
        printf "\n%b\n" "${C_CYAN}--> Добавляю ключ на $host_port_part...${C_RESET}"
        local port_arg=""; if [ -n "$port" ]; then port_arg="-p $port"; fi
        if [ -n "$password" ]; then
            if ! sshpass -p "$password" ssh-copy-id -i "$TEMP_KEY_BASE" $port_arg -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host"; then printf "    %b\n" "${C_RED}❌ Ошибка.${C_RESET}"; else printf "    %b\n" "${C_GREEN}✅ Успех!${C_RESET}"; fi
        else
            if ! ssh-copy-id -i "$TEMP_KEY_BASE" $port_arg -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host"; then printf "    %b\n" "${C_RED}❌ Ошибка.${C_RESET}"; else printf "    %b\n" "${C_GREEN}✅ Успех!${C_RESET}"; fi
        fi
    done < <(grep -v -E '^\s*#|^\s*$' "$SERVERS_FILE_PATH")
    rm -f "$TEMP_KEY_BASE" "$TEMP_KEY_FILE"
    read -p "Хочешь удалить файл со списком серверов '${SERVERS_FILE_PATH}'? (y/n): " cleanup_choice
    if [[ "$cleanup_choice" == "y" || "$cleanup_choice" == "Y" ]]; then rm -f "$SERVERS_FILE_PATH"; fi
    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

security_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Возвращаюсь в главное меню...${C_RESET}"; sleep 1; return' INT
    while true; do
        clear; echo "--- МЕНЮ БЕЗОПАСНОСТИ ---"; echo "   [1] Добавить SSH-ключи на серверы 🔑"; echo "   [b] Назад в главное меню"; 
        read -r -p "Твой выбор: " choice || continue
        case $choice in 1) _ssh_add_keys; wait_for_enter;; [bB]) break;; *) printf "%b\n" "${C_RED}Не та кнопка.${C_RESET}"; sleep 2;; esac
    done
    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

# ============================================================ #
#                   ОБНОВЛЕНИЕ СИСТЕМЫ                         #
# ============================================================ #
system_update_wizard() {
    if ! command -v apt &> /dev/null; then echo "Утилита apt не найдена."; return; fi
    clear; printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"; printf "%b\n" "${C_CYAN}║               ОБНОВЛЕНИЕ СИСТЕМЫ (APT)                       ║${C_RESET}"; printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"; echo ""
    read -p "Запустить полное обновление? (y/n): " confirm_upd
    if [[ "$confirm_upd" == "y" || "$confirm_upd" == "Y" ]]; then
        log "Запущено полное обновление системы..."
        run_cmd apt update && run_cmd apt upgrade -y && run_cmd apt full-upgrade -y && run_cmd apt autoremove -y && run_cmd apt autoclean && run_cmd apt install -y sudo
        save_path "LAST_SYS_UPDATE" "$(date +%Y%m%d)"
        printf "\n%b\n" "${C_GREEN}✅ Система полностью обновлена.${C_RESET}"; log "Обновление системы завершено."; wait_for_enter
    else
        save_path "LAST_SYS_UPDATE" "$(date +%Y%m%d)"; sleep 1
    fi
}
offer_initial_update() {
    local last_check; last_check=$(load_path "LAST_SYS_UPDATE"); local today; today=$(date +%Y%m%d)
    if [ "$last_check" == "$today" ]; then return; fi
    system_update_wizard
}

# ============================================================ #
#               УСТАНОВКА REMNAWAVE (HIGH-LOAD)                #
# ============================================================ #
install_docker_stack() {
    echo -e "${C_YELLOW}Проверка и установка Docker...${C_RESET}"
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
    if ! command -v certbot &> /dev/null; then
        apt-get update && apt-get install -y certbot python3-certbot-dns-cloudflare python3-pip
    fi
}

install_panel_wizard() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_RED}❌ Установка прервана.${C_RESET}"; sleep 1; return' INT

    clear
    printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    printf "%b\n" "${C_CYAN}║       МАСТЕР УСТАНОВКИ ПАНЕЛИ REMNAWAVE                      ║${C_RESET}"
    printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    
    install_docker_stack

    # 1. Выбор компонентов
    echo "--- Выбор компонентов ---"
    read -p "Установить встроенную Ноду (на этом же сервере)? (y/n): " INSTALL_NODE
    read -p "Установить Telegram Бота? (y/n): " INSTALL_BOT
    read -p "Установить Telegram Mini App? (y/n): " INSTALL_MINIAPP
    read -p "Установить TinyAuth (защита входа)? (y/n): " INSTALL_TINYAUTH

    # 2. Сбор доменов
    echo ""
    echo "--- Настройка доменов ---"
    while true; do
        read -p "Введите домен для ПАНЕЛИ (например: panel.example.com): " PANEL_DOMAIN
        if [ -n "$PANEL_DOMAIN" ]; then break; fi
    done

    while true; do
        read -p "Введите домен для ПОДПИСКИ (например: sub.example.com): " SUB_DOMAIN
        if [ -n "$SUB_DOMAIN" ]; then break; fi
    done

    NODE_DOMAIN=""
    if [[ "$INSTALL_NODE" == "y" || "$INSTALL_NODE" == "Y" ]]; then
        while true; do
            read -p "Введите домен для НОДЫ (например: node.example.com): " NODE_DOMAIN
            if [ -n "$NODE_DOMAIN" ]; then break; fi
        done
    fi

    BOT_HOOK_DOMAIN=""
    BOT_API_DOMAIN=""
    if [[ "$INSTALL_BOT" == "y" || "$INSTALL_BOT" == "Y" ]]; then
        while true; do
            read -p "Введите домен для ВЕБХУКОВ бота (например: hooks.example.com): " BOT_HOOK_DOMAIN
            if [ -n "$BOT_HOOK_DOMAIN" ]; then break; fi
        done
        # API домен для бота нужен, если есть MiniApp или внешние запросы
        while true; do
            read -p "Введите домен для API бота (например: api.example.com): " BOT_API_DOMAIN
            if [ -n "$BOT_API_DOMAIN" ]; then break; fi
        done
    fi

    MINIAPP_DOMAIN=""
    if [[ "$INSTALL_MINIAPP" == "y" || "$INSTALL_MINIAPP" == "Y" ]]; then
        while true; do
            read -p "Введите домен для MINI APP (например: app.example.com): " MINIAPP_DOMAIN
            if [ -n "$MINIAPP_DOMAIN" ]; then break; fi
        done
    fi

    AUTH_DOMAIN=""
    if [[ "$INSTALL_TINYAUTH" == "y" || "$INSTALL_TINYAUTH" == "Y" ]]; then
        while true; do
            read -p "Введите домен для АВТОРИЗАЦИИ (например: auth.example.com): " AUTH_DOMAIN
            if [ -n "$AUTH_DOMAIN" ]; then break; fi
        done
    fi

    # 3. Сбор данных (Telegram и Пароли)
    echo ""
    echo "--- Настройка доступов ---"
    
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    if [[ "$INSTALL_BOT" == "y" || "$INSTALL_BOT" == "Y" ]]; then
        while true; do
            read -p "Введите Telegram Bot Token (от @BotFather): " TG_BOT_TOKEN
            if [ -n "$TG_BOT_TOKEN" ]; then break; fi
        done
        while true; do
            read -p "Введите ваш Telegram Chat ID (для уведомлений): " TG_CHAT_ID
            if [ -n "$TG_CHAT_ID" ]; then break; fi
        done
    fi

    # TinyAuth Credentials
    TINYAUTH_BLOCK=""
    NGINX_AUTH_BLOCK=""
    NGINX_AUTH_LOCATION=""
    NGINX_AUTH_INTERNAL=""

    if [[ "$INSTALL_TINYAUTH" == "y" || "$INSTALL_TINYAUTH" == "Y" ]]; then
        echo "Придумайте логин для TinyAuth (например, admin):"
        read TINYAUTH_USER
        [ -z "$TINYAUTH_USER" ] && TINYAUTH_USER="admin"
        
        echo "Придумайте пароль для TinyAuth:"
        read TINYAUTH_PASS
        [ -z "$TINYAUTH_PASS" ] && TINYAUTH_PASS="admin"
        
        echo "Генерация хеша..."
        if command -v python3 &>/dev/null; then
             TINYAUTH_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$TINYAUTH_PASS', bcrypt.gensalt()).decode('utf-8'))" 2>/dev/null || echo "")
        fi
        
        if [ -z "${TINYAUTH_HASH:-}" ]; then
            echo "${C_RED}⚠️ Не удалось сгенерировать хеш. Используем дефолтный пароль 'admin'.${C_RESET}"
            TINYAUTH_HASH='$$2a$$10$$3ZN61q1blIl4sPeAplhGf.L0jCVouaCD.3jAvFIRV1pS1PnQi8be2'
            TINYAUTH_PASS="admin"
        fi
        
        TINYAUTH_SECRET=$(generate_hex 32)
        
        TINYAUTH_BLOCK=$(cat <<EOF
  tinyauth:
    image: ghcr.io/maposia/remnawave-tinyauth:latest
    container_name: tinyauth
    hostname: tinyauth
    restart: always
    ports:
      - '127.0.0.1:3002:3002'
    networks:
      - remnawave-network
    environment:
      - PORT=3002
      - APP_URL=https://${AUTH_DOMAIN}
      - USERS=${TINYAUTH_USER}:${TINYAUTH_HASH}
      - SECRET=${TINYAUTH_SECRET}
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }
EOF
)
        NGINX_AUTH_BLOCK=$(cat <<EOF
    server {
        listen 443 ssl;
        http2 on;
        server_name ${AUTH_DOMAIN};
        ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
        location / {
            proxy_pass http://tinyauth_service;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }
EOF
)
        NGINX_AUTH_LOCATION=$(cat <<EOF
            auth_request /auth_verify;
            error_page 401 = @auth_login;
EOF
)
        NGINX_AUTH_INTERNAL=$(cat <<EOF
        location = /auth_verify {
            internal;
            proxy_pass http://tinyauth_service/api/auth/nginx;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header X-Original-URI \$request_uri;
        }
        location @auth_login {
            internal;
            return 302 https://${AUTH_DOMAIN}/login?redirect_uri=https://\$host\$request_uri;
        }
EOF
)
    fi

    # Генерация внутренних паролей
    POSTGRES_PASSWORD=$(generate_password 24)
    JWT_AUTH_SECRET=$(generate_hex 64)
    JWT_API_TOKENS_SECRET=$(generate_hex 64)
    METRICS_USER=$(generate_password 8)
    METRICS_PASS=$(generate_password 12)

    # 4. SSL Сертификаты
    echo ""
    echo "--- Настройка SSL ---"
    echo "1. Cloudflare API (рекомендуется, нужен токен)"
    echo "2. Standalone (нужны открытые порты 80/443)"
    read -p "Выберите метод (1/2): " SSL_METHOD

    # Собираем список доменов для сертификата
    DOMAINS_LIST="-d $PANEL_DOMAIN -d $SUB_DOMAIN"
    if [ -n "$NODE_DOMAIN" ]; then DOMAINS_LIST="$DOMAINS_LIST -d $NODE_DOMAIN"; fi
    if [ -n "$BOT_HOOK_DOMAIN" ]; then DOMAINS_LIST="$DOMAINS_LIST -d $BOT_HOOK_DOMAIN"; fi
    if [ -n "$BOT_API_DOMAIN" ]; then DOMAINS_LIST="$DOMAINS_LIST -d $BOT_API_DOMAIN"; fi
    if [ -n "$MINIAPP_DOMAIN" ]; then DOMAINS_LIST="$DOMAINS_LIST -d $MINIAPP_DOMAIN"; fi
    if [ -n "$AUTH_DOMAIN" ]; then DOMAINS_LIST="$DOMAINS_LIST -d $AUTH_DOMAIN"; fi

    if [ "$SSL_METHOD" == "1" ]; then
        read -p "Введите Cloudflare API Token: " CF_TOKEN
        read -p "Введите Email аккаунта Cloudflare: " CF_EMAIL
        mkdir -p ~/.secrets/certbot
        echo "dns_cloudflare_api_token = $CF_TOKEN" > ~/.secrets/certbot/cloudflare.ini
        chmod 600 ~/.secrets/certbot/cloudflare.ini
        # Для CF проще взять wildcard, если домены на одном уровне, но для надежности перечислим
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 60 $DOMAINS_LIST \
            --email "$CF_EMAIL" --agree-tos --non-interactive
    else
        read -p "Введите Email для Let's Encrypt: " LE_EMAIL
        certbot certonly --standalone $DOMAINS_LIST --email "$LE_EMAIL" --agree-tos --non-interactive
    fi

    # 5. Создание файлов
    mkdir -p "$REMNA_DIR"
    cd "$REMNA_DIR" || return

    # .env
    cat <<EOF > .env
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL="postgresql://postgres:${POSTGRES_PASSWORD}@remnawave-db:5432/postgres"
REDIS_HOST=remnawave-redis
REDIS_PORT=6379
JWT_AUTH_SECRET=${JWT_AUTH_SECRET}
JWT_API_TOKENS_SECRET=${JWT_API_TOKENS_SECRET}
JWT_AUTH_LIFETIME=168
IS_TELEGRAM_NOTIFICATIONS_ENABLED=true
TELEGRAM_BOT_TOKEN=${TG_BOT_TOKEN}
TELEGRAM_NOTIFY_USERS_CHAT_ID=${TG_CHAT_ID}
TELEGRAM_NOTIFY_NODES_CHAT_ID=${TG_CHAT_ID}
TELEGRAM_NOTIFY_CRM_CHAT_ID=${TG_CHAT_ID}
TELEGRAM_OAUTH_ENABLED=true
FRONT_END_DOMAIN=${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}
IS_DOCS_ENABLED=false
METRICS_USER=${METRICS_USER}
METRICS_PASS=${METRICS_PASS}
WEBHOOK_ENABLED=false
HWID_DEVICE_LIMIT_ENABLED=false
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=true
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80, 95]
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres
REMNAWAVE_PANEL_URL=http://remnawave-scheduler:3000
EOF

    # docker-compose.yml (Base)
    cat <<EOF > docker-compose.yml
x-base: &base
  image: remnawave/backend:latest
  restart: always
  env_file:
    - .env
  networks:
    - remnawave-network
  logging:
    driver: 'json-file'
    options:
      max-size: '25m'
      max-file: '4'

services:
  api:
    <<: *base
    network_mode: "service:remnawave-scheduler"
    networks: {}
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-api'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
      remnawave-scheduler: { condition: service_healthy }

  remnawave-scheduler:
    <<: *base
    container_name: 'remnawave-scheduler'
    hostname: remnawave-scheduler
    entrypoint: ['/bin/sh', 'docker-entrypoint.sh']
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-scheduler'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
    ports:
      - '127.0.0.1:3000:3000'
      - '127.0.0.1:3001:3001'
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

  remnawave-processor:
    <<: *base
    container_name: 'remnawave-processor'
    hostname: remnawave-processor
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-jobs'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
      remnawave-scheduler: { condition: service_healthy }

  remnawave-db:
    image: postgres:17.6
    container_name: 'remnawave-db'
    hostname: remnawave-db
    restart: always
    env_file: [ .env ]
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 10s
      timeout: 5s
      retries: 5

  remnawave-redis:
    image: valkey/valkey:8.1.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    networks:
      - remnawave-network
    volumes:
      - remnawave-redis-data:/data
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 10s
      timeout: 5s
      retries: 5

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave-scheduler:3000
      - APP_PORT=3010
      - META_TITLE=Subscription
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    network_mode: host
    depends_on:
      - api
      - remnawave-subscription-page
    logging:
      driver: 'journald'
      options:
        tag: "nginx.remnawave"

${TINYAUTH_BLOCK}
EOF

    # Добавляем опциональные сервисы в docker-compose
    if [[ "$INSTALL_NODE" == "y" || "$INSTALL_NODE" == "Y" ]]; then
        # Для встроенной ноды нужен секрет. Сгенерируем временный, пользователь потом поменяет
        NODE_SECRET=$(generate_hex 32)
        cat <<EOF >> docker-compose.yml
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=${NODE_SECRET}
    volumes:
      - /dev/shm:/dev/shm:rw
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }
EOF
    fi

    if [[ "$INSTALL_MINIAPP" == "y" || "$INSTALL_MINIAPP" == "Y" ]]; then
        cat <<EOF >> docker-compose.yml
  remnawave-mini-app:
    image: ghcr.io/maposia/remnawave-telegram-sub-mini-app:latest
    container_name: remnawave-telegram-mini-app
    hostname: remnawave-telegram-mini-app
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3020:3020'
    networks:
      - remnawave-network
EOF
    fi

    # Завершаем docker-compose
    cat <<EOF >> docker-compose.yml

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge

volumes:
  remnawave-db-data:
  remnawave-redis-data:
EOF

    # nginx.conf (Base)
    cat <<EOF > nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 4096; }

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 90s;
    client_max_body_size 32M;
    server_names_hash_bucket_size 128;
    server_tokens off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    upstream remnawave_panel_api { server 127.0.0.1:3000; }
    upstream remnawave_subscription_page { server 127.0.0.1:3010; }
    upstream tinyauth_service { server 127.0.0.1:3002; }
    # upstream remnawave_mini_app { server 127.0.0.1:3020; } # Раскомментируется если нужен

    server {
        listen 80;
        server_name _;
        return 301 https://\$host\$request_uri;
    }

${NGINX_AUTH_BLOCK}

    server {
        listen 443 ssl;
        http2 on;
        server_name ${PANEL_DOMAIN};
        ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
        
        location / {
${NGINX_AUTH_LOCATION}
            proxy_pass http://remnawave_panel_api;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
${NGINX_AUTH_INTERNAL}
    }

    server {
        listen 443 ssl;
        http2 on;
        server_name ${SUB_DOMAIN};
        ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
        location / {
            proxy_pass http://remnawave_subscription_page;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
EOF

    # Добавляем блоки в nginx.conf
    if [[ "$INSTALL_NODE" == "y" || "$INSTALL_NODE" == "Y" ]]; then
        cat <<EOF >> nginx.conf
    server {
        server_name ${NODE_DOMAIN};
        listen 443 ssl;
        http2 on;
        ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
        location / {
            proxy_pass http://127.0.0.1:2222;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
    }
EOF
    fi

    if [[ "$INSTALL_MINIAPP" == "y" || "$INSTALL_MINIAPP" == "Y" ]]; then
        # Добавляем апстрим в начало файла (это костыль, но sed справится)
        sed -i '/upstream tinyauth_service/a \    upstream remnawave_mini_app { server 127.0.0.1:3020; }' nginx.conf
        
        cat <<EOF >> nginx.conf
    server {
        listen 443 ssl;
        http2 on;
        server_name ${MINIAPP_DOMAIN};
        ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
        add_header X-Frame-Options "";
        location / {
            proxy_pass http://remnawave_mini_app;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
EOF
    fi

    echo "}" >> nginx.conf # Закрываем http блок

    # 6. Запуск
    echo "Запуск контейнеров..."
    docker compose up -d
    
    echo ""
    printf "%b\n" "${C_GREEN}✅ Установка завершена!${C_RESET}"
    echo "Панель: https://${PANEL_DOMAIN}"
    if [[ "$INSTALL_TINYAUTH" == "y" || "$INSTALL_TINYAUTH" == "Y" ]]; then
        echo "TinyAuth Логин: ${TINYAUTH_USER}"
        echo "TinyAuth Пароль: ${TINYAUTH_PASS}"
    fi
    if [[ "$INSTALL_NODE" == "y" || "$INSTALL_NODE" == "Y" ]]; then
        echo "ВНИМАНИЕ: Для встроенной ноды сгенерирован временный ключ."
        echo "Зайдите в панель -> Создайте ноду -> Скопируйте ключ ->"
        echo "Отредактируйте docker-compose.yml и замените SECRET_KEY -> Перезагрузите (пункт 5)."
    fi
    log "Установка Remnawave завершена."
    wait_for_enter
    
    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

install_node_wizard() {
    clear
    printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    printf "%b\n" "${C_CYAN}║               УСТАНОВКА НОДЫ REMNAWAVE                       ║${C_RESET}"
    printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    
    install_docker_stack
    mkdir -p "$REMNA_DIR"
    cd "$REMNA_DIR" || return

    while true; do
        read -p "Введите домен для ноды (например, node.example.com): " NODE_DOMAIN
        if [ -n "$NODE_DOMAIN" ]; then break; fi
    done

    echo "Вставьте сертификат (Secret Key), полученный в панели:"
    read -p "Key: " NODE_SECRET

    # SSL
    echo ""
    echo "--- Настройка SSL ---"
    echo "1. Cloudflare API"
    echo "2. Standalone"
    read -p "Выберите метод (1/2): " SSL_METHOD

    if [ "$SSL_METHOD" == "1" ]; then
        read -p "Введите Cloudflare API Token: " CF_TOKEN
        read -p "Введите Email аккаунта Cloudflare: " CF_EMAIL
        mkdir -p ~/.secrets/certbot
        echo "dns_cloudflare_api_token = $CF_TOKEN" > ~/.secrets/certbot/cloudflare.ini
        chmod 600 ~/.secrets/certbot/cloudflare.ini
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 60 -d "$NODE_DOMAIN" \
            --email "$CF_EMAIL" --agree-tos --non-interactive
    else
        read -p "Введите Email для Let's Encrypt: " LE_EMAIL
        certbot certonly --standalone -d "$NODE_DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive
    fi

    # docker-compose.yml для ноды
    cat <<EOF > docker-compose.yml
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=${NODE_SECRET}
    volumes:
      - /dev/shm:/dev/shm:rw
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    network_mode: host
EOF

    # nginx.conf для ноды
    cat <<EOF > nginx.conf
server {
    server_name ${NODE_DOMAIN};
    listen 443 ssl;
    http2 on;

    ssl_certificate /etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:2222;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

    docker compose up -d
    echo -e "${C_GREEN}Нода установлена!${C_RESET}"
    wait_for_enter
}

add_node_to_panel_wizard() {
    echo "Функция добавления ноды через API пока в разработке."
    echo "Пожалуйста, добавьте ноду вручную через веб-интерфейс панели."
    wait_for_enter
}

update_remnawave() {
    if [ ! -d "$REMNA_DIR" ]; then echo "Remnawave не установлен."; sleep 2; return; fi
    cd "$REMNA_DIR" || return
    echo "Обновление контейнеров..."
    docker compose pull
    docker compose up -d
    echo -e "${C_GREEN}Обновление завершено.${C_RESET}"
    wait_for_enter
}

restart_remnawave() {
    if [ ! -d "$REMNA_DIR" ]; then echo "Remnawave не установлен."; sleep 2; return; fi
    cd "$REMNA_DIR" || return
    echo "Перезагрузка контейнеров..."
    docker compose restart
    echo -e "${C_GREEN}Перезагрузка завершена.${C_RESET}"
    wait_for_enter
}

uninstall_remnawave() {
    echo -e "${C_RED}ВНИМАНИЕ! ЭТО УДАЛИТ ВСЕ ДАННЫЕ REMNAWAVE (БАЗУ, КОНФИГИ, СЕРТИФИКАТЫ).${C_RESET}"
    read -p "Вы уверены? Введите 'DELETE' для подтверждения: " CONFIRM
    if [ "$CONFIRM" != "DELETE" ]; then echo "Отмена."; sleep 1; return; fi
    
    if [ -d "$REMNA_DIR" ]; then
        cd "$REMNA_DIR" || return
        docker compose down -v
        cd ..
        rm -rf "$REMNA_DIR"
        echo -e "${C_GREEN}Remnawave полностью удален.${C_RESET}"
    else
        echo "Папка $REMNA_DIR не найдена."
    fi
    wait_for_enter
}

remnawave_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Возвращаюсь в главное меню...${C_RESET}"; sleep 1; return' INT

    while true; do
        clear
        printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_CYAN}║               УПРАВЛЕНИЕ REMNAWAVE                           ║${C_RESET}"
        printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
        echo "   [1] Установить Панель (High-Load)"
        echo "   [2] Установить Ноду (Standalone)"
        echo "   [3] Добавить Ноду в Панель (API)"
        echo "   [4] Обновить Панель/Ноду"
        echo "   [5] Перезагрузить Панель/Ноду"
        echo "   [6] Удалить Панель/Ноду (Полная очистка)"
        echo "   [b] Назад в главное меню"
        echo "----------------------------------"
        read -r -p "Твой выбор: " choice || continue

        case $choice in
            1) install_panel_wizard;;
            2) install_node_wizard;;
            3) add_node_to_panel_wizard;;
            4) update_remnawave;;
            5) restart_remnawave;;
            6) uninstall_remnawave;;
            [bB]) break;;
            *) echo "Неверный выбор."; sleep 1;;
        esac
    done
    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

# ============================================================ #
#                   ГЛАВНОЕ МЕНЮ И ИНФО-ПАНЕЛЬ                 #
# ============================================================ #
display_header() {
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}'); local net_status; net_status=$(get_net_status); local cc; cc=$(echo "$net_status" | cut -d'|' -f1); local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2); local cc_status; if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}МАКСИМУМ (bbr + cake)"; else cc_status="${C_GREEN}АКТИВЕН (bbr + $qdisc)"; fi; else cc_status="${C_YELLOW}СТОК ($cc)"; fi; local ipv6_status; ipv6_status=$(check_ipv6_status); local cpu_info; cpu_info=$(get_cpu_info); local cpu_load; cpu_load=$(get_cpu_load); local ram_info; ram_info=$(get_ram_info); local disk_info; disk_info=$(get_disk_info); local hoster_info; hoster_info=$(get_hoster_info); clear; local max_label_width=11; printf "%b\n" "${C_CYAN}╔═[ ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ]${C_RESET}"; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ ИНФО ПО СЕРВЕРУ ]${C_RESET}"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "IP Адрес" "$ip_addr"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Хостер" "$hoster_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Процессор" "$cpu_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Нагрузка" "$cpu_load"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Оперативка" "$ram_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Диск" "$disk_info"; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ СТАТУС СИСТЕМ ]${C_RESET}"; if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE v$PANEL_NODE_VERSION"; else printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE"; fi; if [ "$BOT_DETECTED" -eq 1 ]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Бот" "$BOT_VERSION"; fi; if [[ "$WEB_SERVER" != "Не определён" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Веб-сервер" "$WEB_SERVER"; fi; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ СЕТЕВЫЕ НАСТРОЙКИ ]${C_RESET}"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "Тюнинг" "$cc_status"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "IPv6" "$ipv6_status"; printf "%b\n" "${C_CYAN}╚${C_RESET}";
}
show_menu() {
    trap 'printf "\n%b\n" "${C_YELLOW}⚠️  Не убивай меня! Используй пункт [q] для выхода.${C_RESET}"; sleep 1' INT

    while true; do
        scan_server_state
        check_for_updates
        display_header

        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
            printf "\n%b\n" "${C_RED}${C_BOLD}>>> 🚨 ПОДЪЕХАЛА НОВАЯ ВЕРСИЯ РЕШАЛЫ! ОБНОВИСЬ! 🚨 <<<${C_RESET}"
        fi

        printf "\n%s\n\n" "Чё делать будем, босс?";
        printf "   [0] %b\n" "🔄 Обновить систему (apt update & upgrade)"
        echo "   [1] 🚀 Управление «Форсажем» (BBR+CAKE)"
        echo "   [2] 🌐 Управление IPv6"
        echo "   [3] 📜 Посмотреть журнал «Решалы»"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo "   [4] 🤖 Посмотреть логи Бота"; fi
        if [[ "$SERVER_TYPE" == "Панель" ]]; then echo "   [5] 📊 Посмотреть логи Панели"; elif [[ "$SERVER_TYPE" == "Нода" ]]; then echo "   [5] 📊 Посмотреть логи Ноды"; fi
        printf "   [6] %b\n" "🛡️ Безопасность сервера ${C_YELLOW}(SSH ключи)${C_RESET}"
        printf "   [7] %b\n" "💎 Управление Remnawave ${C_YELLOW}(Установка/Удаление)${C_RESET}"

        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
            printf "   [u] %b\n" "${C_YELLOW}‼️ ОБНОВИТЬ РЕШАЛУ ‼️${C_RESET}"
        elif [[ "$UPDATE_CHECK_STATUS" != "OK" ]]; then
            printf "\n%b\n" "${C_RED}⚠️ Ошибка проверки обновлений (см. лог)${C_RESET}"
        fi

        echo ""
        printf "   [d] %b\n" "${C_RED}🗑️ Снести Решалу нахуй (Удаление)${C_RESET}"
        echo "   [q] 🚪 Свалить (Выход)"
        echo "------------------------------------------------------"
        read -r -p "Твой выбор, босс: " choice || continue

        log "Пользователь выбрал пункт меню: $choice"

        case $choice in
            0) system_update_wizard;;
            1) apply_bbr; wait_for_enter;;
            2) ipv6_menu;;
            3) view_logs_realtime "$LOGFILE" "Решалы";;
            4) if [ "$BOT_DETECTED" -eq 1 ]; then view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота"; else echo "Нет такой кнопки."; sleep 2; fi;;
            5) if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE"; else echo "Нет такой кнопки."; sleep 2; fi;;
            6) security_menu;;
            7) remnawave_menu;;
            [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой?"; sleep 2; fi;;
            [dD]) uninstall_script;;
            [qQ]) echo "Был рад помочь. Не обосрись. 🥃"; break;;
            *) echo "Ты прикалываешься?"; sleep 2;;
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
    
    log "Запуск скрипта Решала ${VERSION}"

    if [[ "${1:-}" == "install" ]]; then
        install_script "${2:-}"
    else
        if [[ $EUID -ne 0 ]]; then 
            if [ "$0" != "$INSTALL_PATH" ]; then printf "%b\n" "${C_RED}❌ Запускать с 'sudo'.${C_RESET} Используй: ${C_YELLOW}sudo ./$0 install${C_RESET}"; else printf "%b\n" "${C_RED}❌ Только для рута. Используй: ${C_YELLOW}sudo reshala${C_RESET}"; fi
            exit 1;
        fi
        trap "rm -f /tmp/tmp.*" EXIT
        offer_initial_update
        show_menu
    fi
}

main "$@"