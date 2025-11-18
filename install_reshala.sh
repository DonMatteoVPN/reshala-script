#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v1.4 - LOCALHOST SUPPORT   ==
# ============================================================ #
# ==    Добавлена поддержка localhost и улучшены шаблоны.     ==
# ============================================================ #

set -euo pipefail

# ============================================================ #
#                  КОНСТАНТЫ И ПЕРЕМЕННЫЕ                      #
# ============================================================ #
readonly VERSION="v1.4"
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/dev/install_reshala.sh"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala_ops.log"
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
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | run_cmd tee -a "$LOGFILE"; }
wait_for_enter() { read -p $'\nНажми Enter, чтобы продолжить...'; }
save_path() { local key="$1"; local value="$2"; touch "$CONFIG_FILE"; sed -i "/^$key=/d" "$CONFIG_FILE"; echo "$key=\"$value\"" >> "$CONFIG_FILE"; }
load_path() { local key="$1"; [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" &>/dev/null; eval echo "\${$key:-}"; }
get_net_status() { local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a"); local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a"); if [ -z "$qdisc" ] || [ "$qdisc" = "pfifo_fast" ]; then qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n 1) || qdisc="n/a"; fi; echo "$cc|$qdisc"; }

# ============================================================ #
#                 УСТАНОВКА И ОБНОВЛЕНИЕ СКРИПТА               #
# ============================================================ #
install_script() {
    if [[ $EUID -ne 0 ]]; then printf "%b\n" "${C_RED}❌ Эту команду — только с 'sudo'.${C_RESET}"; exit 1; fi
    printf "%b\n" "${C_CYAN}🚀 Интегрирую Решалу ${VERSION} в систему...${C_RESET}"; local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    if ! wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL"; then printf "%b\n" "${C_RED}❌ Не могу скачать последнюю версию. Проверь интернет или ссылку.${C_RESET}"; exit 1; fi
    run_cmd cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && run_cmd chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"
    if ! grep -q "alias reshala='sudo reshala'" /root/.bashrc 2>/dev/null; then echo "alias reshala='sudo reshala'" | run_cmd tee -a /root/.bashrc >/dev/null; fi
    printf "\n%b\n\n" "${C_GREEN}✅ Готово. Решала в системе.${C_RESET}"; if [[ $(id -u) -eq 0 ]]; then printf "   %b: %b\n" "${C_BOLD}Команда запуска" "${C_YELLOW}reshala${C_RESET}"; else printf "   %b: %b\n" "${C_BOLD}Команда запуска" "${C_YELLOW}sudo reshala${C_RESET}"; fi
    printf "   %b\n" "${C_RED}⚠️ ВАЖНО: ПЕРЕПОДКЛЮЧИСЬ к серверу, чтобы команда заработала.${C_RESET}"; if [[ "${1:-}" != "update" ]]; then printf "   %s\n" "Установочный файл ('$0') можешь сносить."; fi
}
check_for_updates() {
    UPDATE_AVAILABLE=0; LATEST_VERSION=""; UPDATE_CHECK_STATUS="OK"; local max_attempts=3; local attempt=1; local response_body=""; local curl_exit_code=0; local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"; log "Начинаю проверку обновлений по URL: $url_with_buster"
    while [ $attempt -le $max_attempts ]; do
        response_body=$(curl -4 -L --connect-timeout 7 --max-time 15 --retry 2 --retry-delay 3 "$url_with_buster" 2> >(sed 's/^/curl-error: /' >> "$LOGFILE")); curl_exit_code=$?
        if [ $curl_exit_code -eq 0 ] && [ -n "$response_body" ]; then
            LATEST_VERSION=$(echo "$response_body" | grep -m 1 'readonly VERSION' | cut -d'"' -f2)
            if [ -n "$LATEST_VERSION" ]; then
                log "Удалённая версия: $LATEST_VERSION. Локальная: $VERSION."; local local_ver_num; local_ver_num=$(echo "$VERSION" | sed 's/[^0-9.]*//g'); local remote_ver_num; remote_ver_num=$(echo "$LATEST_VERSION" | sed 's/[^0-9.]*//g')
                if [[ "$local_ver_num" != "$remote_ver_num" ]]; then local highest_ver_num; highest_ver_num=$(printf '%s\n%s' "$local_ver_num" "$remote_ver_num" | sort -V | tail -n1); if [[ "$highest_ver_num" == "$remote_ver_num" ]]; then UPDATE_AVAILABLE=1; log "Обнаружена новая версия (числовое сравнение: $remote_ver_num > $local_ver_num)."; fi; fi; return 0
            else log "Попытка $attempt: Ответ получен, но не могу найти строку с версией."; fi
        else log "Попытка $attempt из $max_attempts не удалась (код выхода curl: $curl_exit_code)."; if [ $attempt -lt $max_attempts ]; then sleep 3; fi; fi; attempt=$((attempt + 1))
    done; UPDATE_CHECK_STATUS="ERROR"; log "Ошибка проверки обновлений после $max_attempts попыток."; return 1
}
run_update() {
    read -p "   Доступна версия $LATEST_VERSION. Обновляемся, или дальше на старье пердеть будем? (y/n): " confirm_update
    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then printf "%b\n" "${C_YELLOW}🤷‍♂️ Ну и сиди со старьём. Твоё дело.${C_RESET}"; wait_for_enter; return; fi
    printf "%b\n" "${C_CYAN}🔄 Качаю свежак...${C_RESET}"; local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp); local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
    if ! wget -4 --timeout=20 --tries=3 --retry-connrefused -q -O "$TEMP_SCRIPT" "$url_with_buster"; then printf "%b\n" "${C_RED}❌ Хуйня какая-то. Не могу скачать обнову. Проверь инет и лог /var/log/reshala_ops.log.${C_RESET}"; log "wget не смог скачать $url_with_buster"; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; fi
    local downloaded_version; downloaded_version=$(grep -m 1 'readonly VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)
    if [ ! -s "$TEMP_SCRIPT" ] || ! bash -n "$TEMP_SCRIPT" 2>/dev/null || [ "$downloaded_version" != "$LATEST_VERSION" ]; then printf "%b\n" "${C_RED}❌ Скачалось какое-то дерьмо, а не скрипт. Отбой.${C_RESET}"; log "Скачанный файл обновления не прошел проверку. Ожидалась версия $LATEST_VERSION, в файле $downloaded_version."; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; fi
    echo "   Ставлю на место старого..."; run_cmd cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && run_cmd chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"; printf "${C_GREEN}✅ Готово. Теперь у тебя версия %s. Не благодари.${C_RESET}\n" "$LATEST_VERSION"; echo "   Перезапускаю себя, чтобы мозги встали на место..."; sleep 2; exec "$INSTALL_PATH"
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
apply_bbr() { log "🚀 ЗАПУСК ТУРБОНАДДУВА (BBR/CAKE)..."; local net_status; net_status=$(get_net_status); local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1); local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2); local cake_available; cake_available=$(modprobe sch_cake &>/dev/null && echo "true" || echo "false"); echo "--- ДИАГНОСТИКА ТВОЕГО ДВИГАТЕЛЯ ---"; echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"; echo "------------------------------------"; if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then printf "%b\n" "${C_GREEN}✅ Ты уже на максимальном форсаже (BBR+CAKE). Не мешай машине работать.${C_RESET}"; log "Проверка «Форсаж»: Максимум."; return; fi; if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "fq" && "$cake_available" == "true" ]]; then printf "%b\n" "${C_YELLOW}⚠️ У тебя неплохо (BBR+FQ), но можно лучше. CAKE доступен.${C_RESET}"; read -p "   Хочешь проапгрейдиться до CAKE? Это топчик. (y/n): " upgrade_confirm; if [[ "$upgrade_confirm" != "y" && "$upgrade_confirm" != "Y" ]]; then echo "Как скажешь. Остаёмся на FQ."; return; fi; echo "Красава. Делаем как надо."; elif [[ "$current_cc" != "bbr" && "$current_cc" != "bbr2" ]]; then echo "Хм, ездишь на стоке. Пора залить ракетное топливо."; fi; local available_cc; available_cc=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}'); local preferred_cc="bbr"; if [[ "$available_cc" == *"bbr2"* ]]; then preferred_cc="bbr2"; fi; local preferred_qdisc="fq"; if [[ "$cake_available" == "true" ]]; then preferred_qdisc="cake"; else log "⚠️ 'cake' не найден, ставлю 'fq'."; modprobe sch_fq &>/dev/null; fi; local tcp_fastopen_val=0; [[ $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0) -ge 1 ]] && tcp_fastopen_val=3; local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"; log "🧹 Чищу старое говно..."; run_cmd rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf; if [ -f /etc/sysctl.conf.bak ]; then run_cmd rm /etc/sysctl.conf.bak; fi; run_cmd sed -i.bak -E 's/^[[:space:]]*(net.core.default_qdisc|net.ipv4.tcp_congestion_control)/#&/' /etc/sysctl.conf; log "✍️  Устанавливаю новые, пиздатые настройки..."; echo "# === КОНФИГ «ФОРСАЖ» ОТ РЕШАЛЫ — НЕ ТРОГАТЬ ===
net.ipv4.tcp_congestion_control = $preferred_cc
net.core.default_qdisc = $preferred_qdisc
net.ipv4.tcp_fastopen = $tcp_fastopen_val
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216" | run_cmd tee "$CONFIG_SYSCTL" > /dev/null; log "🔥 Применяю настройки..."; run_cmd sysctl -p "$CONFIG_SYSCTL" >/dev/null; echo ""; echo "--- КОНТРОЛЬНЫЙ ВЫСТРЕЛ ---"; echo "Новый алгоритм: $(sysctl -n net.ipv4.tcp_congestion_control)"; echo "Новый планировщик: $(sysctl -n net.core.default_qdisc)"; echo "---------------------------"; printf "%b\n" "${C_GREEN}✅ Твоя тачка теперь — ракета. (CC: $preferred_cc, QDisc: $preferred_qdisc)${C_RESET}"; }
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
ipv6_menu() { while true; do clear; echo "--- УПРАВЛЕНИЕ IPv6 ---"; printf "Статус IPv6: %b\n" "$(check_ipv6_status)"; echo "--------------------------"; echo "   1. Кастрировать (Отключить)"; echo "   2. Реанимировать (Включить)"; echo "   b. Назад в главное меню"; read -r -p "Твой выбор: " choice; case $choice in 1) disable_ipv6; wait_for_enter;; 2) enable_ipv6; wait_for_enter;; [bB]) break;; *) echo "1, 2 или 'b'. Не тупи."; sleep 2;; esac; done; }
view_logs_realtime() { local log_path="$1"; local log_name="$2"; if [ ! -f "$log_path" ]; then printf "%b\n" "❌ ${C_RED}Лог '$log_name' пуст.${C_RESET}"; sleep 2; return; fi; echo "[*] Смотрю журнал '$log_name'... (CTRL+C, чтобы свалить)"; local original_int_handler=$(trap -p INT); trap "printf '\n%b\n' '${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT; (run_cmd tail -f -n 50 "$log_path" | awk -F ' - ' -v C_YELLOW="$C_YELLOW" -v C_RESET="$C_RESET" '{print C_YELLOW $1 C_RESET "  " $2}') || true; if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi; return 0; }
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
#
# --- ПРИМЕРЫ ---
#
# 1. Простой IP, без пароля (запросит вручную)
# root@11.22.33.44
#
# 2. Сервер с простым паролем (авто-вход)
# user@myserver.com MyPassword123
#
# 3. Пароль со спецсимволом '$' (нужно экранирование)
# user@problem.server MyPa\$\$wordWithDollar
#
# 4. Пароль с пробелами и спецсимволами (лучше в кавычках)
# user@super.server 'My Crazy Password !@# %'
#
# --- ДОБАВЛЕНИЕ КЛЮЧА НА ТЕКУЩИЙ СЕРВЕР ---
#
# Чтобы добавить ключ на этот же сервер, где запущен "Решала",
# используй специальный адрес 'localhost'. Пароль не нужен.
# root@localhost
#
# ВНИМАНИЕ: Не добавляйте в этот список IP-адрес ТЕКУЩЕГО сервера,
# на котором запущен "Решала". Это бессмысленно и может вызвать ошибки.
#
# --- ДОБАВЬ СВОИ СЕРВЕРЫ НИЖЕ ---

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
    fi
    
    chmod 700 /root/.ssh
    chmod 600 "$auth_keys_file"
}
ssh_key_manager() {
    clear; printf "%b\n" "${C_CYAN}--- МАССОВОЕ ДОБАВЛЕНИЕ SSH-КЛЮЧЕЙ ---${C_RESET}"; printf "%s\n" "Этот модуль поможет тебе закинуть твой SSH-ключ на все твои серверы.";
    
    printf "\n%b\n" "${C_BOLD}[ ШАГ 1: Подготовь публичный ключ ]${C_RESET}"; printf "%b\n" "Эти команды нужно выполнять на ${C_YELLOW}ТВОЁМ ЛИЧНОМ КОМПЬЮТЕРЕ${C_RESET}, а не на этом сервере."; printf "\n%b\n" "${C_CYAN}--- Для Windows ---${C_RESET}"; printf "%s\n" "1. Открой 'Командную строку' (cmd) или 'PowerShell'."; printf "%s\n" "2. Если ключ не создан, выполни команду (просто нажимай Enter на все вопросы):"; printf "   %b\n" "${C_GREEN}ssh-keygen -t ed25519${C_RESET}"; printf "%b\n" "3. Чтобы посмотреть и скопировать твой ${C_YELLOW}ПУБЛИЧНЫЙ${C_RESET} ключ, выполни:"; printf "   %b\n" "${C_GREEN}type %USERPROFILE%\\.ssh\\id_ed25519.pub${C_RESET}"; printf "%s\n" "   (Если команда выдаёт ошибку, значит ключ не найден. Вернись к пункту 2)."; printf "\n%b\n" "${C_CYAN}--- Для Linux или macOS ---${C_RESET}"; printf "%s\n" "1. Открой терминал."; printf "%b\n" "2. Если ключ не создан, выполни: ${C_GREEN}ssh-keygen -t ed25519${C_RESET}"; printf "%b\n" "3. Посмотри и скопируй твой ${C_YELLOW}ПУБЛИЧНЫЙ${C_RESET} ключ: ${C_GREEN}cat ~/.ssh/id_ed25519.pub${C_RESET}"; printf "\n%s\n" "Скопируй всю строку, которая начинается с 'ssh-ed25519...'.";
    
    read -p $'\nТы скопировал свой ПУБЛИЧНЫЙ ключ и готов продолжить? (y/n): ' confirm_key; if [[ "$confirm_key" != "y" && "$confirm_key" != "Y" ]]; then printf "\n%b\n" "${C_RED}Отмена. Возвращаю в меню.${C_RESET}"; sleep 2; return; fi; printf "\n%b\n" "${C_BOLD}[ ШАГ 2: Вставь свой ключ ]${C_RESET}"; read -p "Вставь сюда свой публичный ключ (ssh-ed25519...): " PUBKEY; if ! [[ "$PUBKEY" =~ ^ssh-(rsa|dss|ed25519|ecdsa) ]]; then printf "\n%b\n" "${C_RED}❌ Это не похоже на SSH-ключ. Давай по новой.${C_RESET}"; return; fi;
    
    local SERVERS_FILE_PATH; SERVERS_FILE_PATH="$(pwd)/servers.txt"
    printf "\n%b\n" "${C_BOLD}[ ШАГ 3: Управление списком серверов ]${C_RESET}"
    if [ -f "$SERVERS_FILE_PATH" ]; then
        printf "%b\n" "Найден существующий файл со списком серверов: ${C_YELLOW}${SERVERS_FILE_PATH}${C_RESET}"
        read -p "Что делаем? (1-Редактировать, 2-Использовать как есть, 3-Удалить и создать заново): " choice
        case $choice in
            1) _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return ;;
            2) printf "%b\n" "Продолжаю с текущим списком..." ;;
            3) rm -f "$SERVERS_FILE_PATH"; _create_servers_file_template "$SERVERS_FILE_PATH"; _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return ;;
            *) printf "\n%b\n" "${C_RED}Отмена. Возвращаю в меню.${C_RESET}"; return ;;
        esac
    else
        printf "%b\n" "Файл со списком серверов не найден. Создаю новый с инструкциями."
        _create_servers_file_template "$SERVERS_FILE_PATH"
        read -p "Нажми Enter, чтобы открыть редактор 'nano' для добавления серверов..."
        _ensure_package_installed "nano" && nano "$SERVERS_FILE_PATH" || return
    fi
    printf "%b\n" "Файл готов. Он лежит здесь: ${C_YELLOW}${SERVERS_FILE_PATH}${C_RESET}"
    if ! grep -q -E '[^[:space:]]' "$SERVERS_FILE_PATH" || ! grep -v -E '^\s*#|^\s*$' "$SERVERS_FILE_PATH" | read -r; then printf "\n%b\n" "${C_RED}❌ Файл со списком серверов пуст или содержит только комментарии. Операция прервана.${C_RESET}"; return; fi

    printf "\n%b\n" "${C_BOLD}[ ШАГ 4: Установка ключа на серверы ]${C_RESET}"; printf "%s\n" "Сейчас я буду по очереди подключаться к каждому серверу."; _ensure_package_installed "sshpass" || return; wait_for_enter;
    local TEMP_KEY_FILE; TEMP_KEY_FILE=$(mktemp); echo "$PUBKEY" > "$TEMP_KEY_FILE"
    
    while read -r -a parts; do
        [[ -z "${parts[0]}" ]] || [[ "${parts[0]}" =~ ^# ]] && continue
        local host="${parts[0]}"
        local password="${parts[*]:1}"
        
        if [[ "$host" == "root@localhost" || "$host" == "root@127.0.0.1" ]]; then
            _add_key_locally "$PUBKEY"
            continue
        fi

        printf "\n%b\n" "${C_CYAN}--> Добавляю ключ на $host...${C_RESET}"
        
        local ssh_copy_id_cmd="ssh-copy-id -i $TEMP_KEY_FILE -o ConnectTimeout=10 -o StrictHostKeyChecking=no '$host'"
        
        if [ -n "$password" ]; then
            printf "%b\n" "${C_GRAY}    (использую пароль из файла)${C_RESET}"
            if ! sshpass -p "$password" sh -c "$ssh_copy_id_cmd"; then
                printf "    %b\n" "${C_RED}❌ Ошибка. Автоматический вход не удался. Проверь пароль в файле.${C_RESET}"
            else
                printf "    %b\n" "${C_GREEN}✅ Успех!${C_RESET}"
            fi
        else
            printf "%b\n" "${C_GRAY}    (пароль не указан, будет запрошен вручную)${C_RESET}"
            if ! sh -c "$ssh_copy_id_cmd"; then
                printf "    %b\n" "${C_RED}❌ Ошибка. Проверь введённый пароль или доступность хоста.${C_RESET}"
            else
                printf "    %b\n" "${C_GREEN}✅ Успех!${C_RESET}"
            fi
        fi
    done < <(grep -v -E '^\s*#|^\s*$' "$SERVERS_FILE_PATH")
    rm "$TEMP_KEY_FILE"
    
    printf "\n%b\n" "${C_GREEN}🎉 Готово! Процесс завершён.${C_RESET}"
    read -p "Хочешь удалить файл со списком серверов '${SERVERS_FILE_PATH}'? (y/n): " cleanup_choice
    if [[ "$cleanup_choice" == "y" || "$cleanup_choice" == "Y" ]]; then rm -f "$SERVERS_FILE_PATH"; printf "%b\n" "${C_GREEN}✅ Файл удалён.${C_RESET}"; fi
}
security_menu() {
    while true; do
        clear; echo "--- МЕНЮ БЕЗОПАСНОСТИ ---"; echo "Здесь собраны инструменты для укрепления твоего сервера."; echo "----------------------------------"; echo "   [1] Массовое добавление SSH-ключей 🔑"; echo "   [b] Назад в главное меню"; echo "----------------------------------"; read -r -p "Твой выбор: " choice
        case $choice in 1) ssh_key_manager; wait_for_enter;; [bB]) break;; *) echo "Не та кнопка, босс."; sleep 2;; esac
    done
}

# ============================================================ #
#                   ГЛАВНОЕ МЕНЮ И ИНФО-ПАНЕЛЬ                 #
# ============================================================ #
display_header() {
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}'); local net_status; net_status=$(get_net_status); local cc; cc=$(echo "$net_status" | cut -d'|' -f1); local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2); local cc_status; if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}МАКСИМУМ (bbr + cake)"; else cc_status="${C_GREEN}АКТИВЕН (bbr + $qdisc)"; fi; else cc_status="${C_YELLOW}СТОК ($cc)"; fi; local ipv6_status; ipv6_status=$(check_ipv6_status); local cpu_info; cpu_info=$(get_cpu_info); local cpu_load; cpu_load=$(get_cpu_load); local ram_info; ram_info=$(get_ram_info); local disk_info; disk_info=$(get_disk_info); local hoster_info; hoster_info=$(get_hoster_info); clear; local max_label_width=11; printf "%b\n" "${C_CYAN}╔═[ ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ]${C_RESET}"; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ ИНФО ПО СЕРВЕРУ ]${C_RESET}"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "IP Адрес" "$ip_addr"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Хостер" "$hoster_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Процессор" "$cpu_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Нагрузка" "$cpu_load"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Оперативка" "$ram_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Диск" "$disk_info"; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ СТАТУС СИСТЕМ ]${C_RESET}"; if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE v$PANEL_NODE_VERSION"; else printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE"; fi; if [ "$BOT_DETECTED" -eq 1 ]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Бот" "$BOT_VERSION"; fi; if [[ "$WEB_SERVER" != "Не определён" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Веб-сервер" "$WEB_SERVER"; fi; printf "%b\n" "${C_CYAN}║${C_RESET}"; printf "%b\n" "${C_CYAN}╠═[ СЕТЕВЫЕ НАСТРОЙКИ ]${C_RESET}"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "Тюнинг" "$cc_status"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "IPv6" "$ipv6_status"; printf "%b\n" "${C_CYAN}╚${C_RESET}";
}
show_menu() {
    while true; do
        scan_server_state; display_header; check_for_updates
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then printf "\n%b\n" "${C_YELLOW}🔥 Новая версия на подходе: ${LATEST_VERSION}${C_RESET}"; elif [[ "$UPDATE_CHECK_STATUS" != "OK" ]]; then printf "\n%b\n" "${C_RED}⚠️ Ошибка проверки обновлений (см. лог)${C_RESET}"; fi
        printf "\n%s\n\n" "Чё делать будем, босс?"; echo "   [1] Управление «Форсажем» (BBR+CAKE)"; echo "   [2] Управление IPv6"; echo "   [3] Посмотреть журнал «Форсажа»"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo "   [4] Посмотреть логи Бота 🤖"; fi
        if [[ "$SERVER_TYPE" == "Панель" ]]; then echo "   [5] Посмотреть логи Панели 📊"; elif [[ "$SERVER_TYPE" == "Нода" ]]; then echo "   [5] Посмотреть логи Ноды 📊"; fi
        printf "   [6] %b\n" "Безопасность сервера ${C_YELLOW}(На начальной стадии)${C_RESET}"
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then printf "   [u] %b\n" "${C_YELLOW}ОБНОВИТЬ РЕШАЛУ${C_RESET}"; fi
        echo ""; printf "   [d] %b\n" "${C_RED}Снести Решалу нахуй (Удаление)${C_RESET}"; echo "   [q] Свалить (Выход)"; echo "------------------------------------------------------"; read -r -p "Твой выбор, босс: " choice
        case $choice in
            1) apply_bbr; wait_for_enter;; 2) ipv6_menu;; 3) view_logs_realtime "$LOGFILE" "Форсажа";; 4) if [ "$BOT_DETECTED" -eq 1 ]; then view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота"; else echo "Нет такой кнопки."; sleep 2; fi;; 5) if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE"; else echo "Нет такой кнопки."; sleep 2; fi;; 6) security_menu;; [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой?"; sleep 2; fi;; [dD]) uninstall_script;; [qQ]) echo "Был рад помочь. Не обосрись. 🥃"; break;; *) echo "Ты прикалываешься?"; sleep 2;;
        esac
    done
}

# ============================================================ #
#                       ТОЧКА ВХОДА В СКРИПТ                   #
# ============================================================ #
if [[ "${1:-}" == "install" ]]; then
    install_script "${2:-}"
else
    if [[ $EUID -ne 0 ]]; then 
        if [ "$0" != "$INSTALL_PATH" ]; then printf "%b\n" "${C_RED}❌ Запускать с 'sudo'.${C_RESET} Используй: ${C_YELLOW}sudo ./$0 install${C_RESET}"; else printf "%b\n" "${C_RED}❌ Только для рута. Используй: ${C_YELLOW}sudo reshala${C_RESET}"; fi
        exit 1;
    fi
    trap - INT TERM EXIT
    show_menu
fi