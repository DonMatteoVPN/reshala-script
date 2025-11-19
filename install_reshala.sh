#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v1.994 - REFACTORED          ==
# ============================================================ #
# ==    1. Безопасная работа с SSH (файлы удаляются сами).  ==
# ==    2. Защита от битых обновлений.                      ==
# ==    3. Оптимизация кода и проверок.                     ==
# ============================================================ #

set -uo pipefail

# ============================================================ #
#                  КОНСТАНТЫ И ПЕРЕМЕННЫЕ                      #
# ============================================================ #
readonly VERSION="v1.994"
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
LATEST_VERSION=""; UPDATE_CHECK_STATUS="Check...";

# ============================================================ #
#                     УТИЛИТАРНЫЕ ФУНКЦИИ                      #
# ============================================================ #
# Мы уже root, sudo не нужен. Функция просто выполняет команду и пишет ошибки если есть.
run_cmd() { 
    "$@" 
    local status=$?
    if [ $status -ne 0 ]; then
        # Можно включить дебаг, раскомментировав строку ниже
        # echo "Ошибка при выполнении: $* (Код: $status)" >> "$LOGFILE"
        return $status
    fi
}

log() { 
    if [ ! -f "$LOGFILE" ]; then 
        touch "$LOGFILE" && chmod 666 "$LOGFILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | tee -a "$LOGFILE" > /dev/null
}

wait_for_enter() { read -p $'\nНажми Enter, чтобы продолжить...'; }
save_path() { local key="$1"; local value="$2"; touch "$CONFIG_FILE"; sed -i "/^$key=/d" "$CONFIG_FILE"; echo "$key=\"$value\"" >> "$CONFIG_FILE"; }
load_path() { local key="$1"; [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" &>/dev/null; eval echo "\${$key:-}"; }

get_net_status() { 
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a"); 
    local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a"); 
    # Если qdisc стандартный, пробуем найти более точный через tc (но это ненадежно)
    if [ -z "$qdisc" ] || [ "$qdisc" = "pfifo_fast" ]; then 
        qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n 1) || qdisc="n/a"; 
    fi; 
    echo "$cc|$qdisc"; 
}

# ============================================================ #
#                 УСТАНОВКА И ОБНОВЛЕНИЕ СКРИПТА               #
# ============================================================ #
install_script() {
    if [[ $EUID -ne 0 ]]; then printf "%b\n" "${C_RED}❌ Эту команду — только с 'sudo'.${C_RESET}"; exit 1; fi
    
    printf "%b\n" "${C_CYAN}🚀 Интегрирую Решалу ${VERSION} в систему...${C_RESET}"
    local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    
    if ! wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL"; then 
        printf "%b\n" "${C_RED}❌ Не могу скачать последнюю версию. Проверь интернет.${C_RESET}"
        rm -f "$TEMP_SCRIPT"
        exit 1
    fi

    # Проверка целостности
    if [ ! -s "$TEMP_SCRIPT" ] || ! grep -q "readonly VERSION" "$TEMP_SCRIPT"; then
        printf "%b\n" "${C_RED}❌ Скачанный файл битый. Отмена.${C_RESET}"
        rm -f "$TEMP_SCRIPT"
        exit 1
    fi

    cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && chmod +x "$INSTALL_PATH"
    rm "$TEMP_SCRIPT"
    
    if ! grep -q "alias reshala='sudo reshala'" /root/.bashrc 2>/dev/null; then 
        echo "alias reshala='sudo reshala'" | tee -a /root/.bashrc >/dev/null
    fi
    
    log "Скрипт установлен (версия ${VERSION})."
    printf "\n%b\n\n" "${C_GREEN}✅ Готово. Решала в системе.${C_RESET}"
    printf "   %b: %b\n" "${C_BOLD}Команда запуска" "${C_YELLOW}reshala${C_RESET}"
    printf "   %b\n" "${C_RED}⚠️ ВАЖНО: ПЕРЕПОДКЛЮЧИСЬ к серверу, чтобы команда заработала.${C_RESET}"
}

check_for_updates() {
    UPDATE_AVAILABLE=0; LATEST_VERSION=""; UPDATE_CHECK_STATUS="Check..."; 
    local response_body=""; local curl_exit_code=0; 
    local url_with_buster="${SCRIPT_URL}?cb=$(date +%s)"
    
    # Таймаут 5 сек, чтобы меню не тупило
    response_body=$(curl -s -4 -L --connect-timeout 5 --max-time 10 "$url_with_buster"); curl_exit_code=$?
    
    if [ $curl_exit_code -eq 0 ] && [ -n "$response_body" ]; then
        # Более надежный парсинг версии
        LATEST_VERSION=$(echo "$response_body" | grep -m 1 'readonly VERSION=' | cut -d'"' -f2)
        
        if [ -n "$LATEST_VERSION" ]; then
            local local_ver_num; local_ver_num=$(echo "$VERSION" | sed 's/[^0-9.]*//g')
            local remote_ver_num; remote_ver_num=$(echo "$LATEST_VERSION" | sed 's/[^0-9.]*//g')
            
            # Сравнение версий через sort -V
            if [[ "$local_ver_num" != "$remote_ver_num" ]]; then 
                local highest_ver_num; highest_ver_num=$(printf '%s\n%s' "$local_ver_num" "$remote_ver_num" | sort -V | tail -n1)
                if [[ "$highest_ver_num" == "$remote_ver_num" ]]; then UPDATE_AVAILABLE=1; fi
            fi
            UPDATE_CHECK_STATUS="OK"
        else 
            UPDATE_CHECK_STATUS="ParseErr"
        fi
    else 
        UPDATE_CHECK_STATUS="NetErr"
    fi
}

run_update() {
    read -p "   Доступна версия $LATEST_VERSION. Обновляемся? (y/n): " confirm_update
    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then printf "%b\n" "${C_YELLOW}🤷‍♂️ Хозяин - барин.${C_RESET}"; wait_for_enter; return; fi
    
    printf "%b\n" "${C_CYAN}🔄 Качаю свежак...${C_RESET}"
    local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    local url_with_buster="${SCRIPT_URL}?cb=$(date +%s)"
    
    if ! wget -4 --timeout=20 -q -O "$TEMP_SCRIPT" "$url_with_buster"; then 
        printf "%b\n" "${C_RED}❌ Ошибка скачивания.${C_RESET}"; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; 
    fi
    
    # Проверка валидности bash скрипта перед заменой
    if ! bash -n "$TEMP_SCRIPT" 2>/dev/null; then
        printf "%b\n" "${C_RED}❌ Скачанный файл содержит ошибки синтаксиса. Отмена.${C_RESET}"
        rm -f "$TEMP_SCRIPT"; wait_for_enter; return
    fi

    local downloaded_version; downloaded_version=$(grep -m 1 'readonly VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)
    if [ "$downloaded_version" != "$LATEST_VERSION" ]; then
        printf "%b\n" "${C_YELLOW}⚠️ Версия в файле ($downloaded_version) не совпадает с ожидаемой. Но пох, ставим.${C_RESET}"
    fi

    cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && chmod +x "$INSTALL_PATH"
    rm "$TEMP_SCRIPT"
    
    log "✅ Скрипт обновлён до $LATEST_VERSION."
    printf "${C_GREEN}✅ Готово. Перезапускаюсь...${C_RESET}\n"; sleep 1; exec "$INSTALL_PATH"
}

# ============================================================ #
#                 СБОР ИНФОРМАЦИИ О СИСТЕМЕ                    #
# ============================================================ #
get_docker_version() { 
    local container_name="$1"; 
    # Попытка 1: Labels
    local version=""; version=$(docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$container_name" 2>/dev/null); 
    if [ -n "$version" ]; then echo "$version"; return; fi; 
    # Попытка 2: ENV
    version=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null | grep -E '^(APP_VERSION|VERSION)=' | head -n 1 | cut -d'=' -f2); 
    if [ -n "$version" ]; then echo "$version"; return; fi; 
    # Попытка 3: package.json (только если есть jq)
    if command -v jq &>/dev/null; then
        if docker exec "$container_name" test -f /app/package.json 2>/dev/null; then 
            version=$(docker exec "$container_name" cat /app/package.json 2>/dev/null | jq -r .version 2>/dev/null); 
            if [ -n "$version" ] && [ "$version" != "null" ]; then echo "$version"; return; fi; 
        fi
    fi
    # Попытка 4: Файл VERSION
    if docker exec "$container_name" test -f /app/VERSION 2>/dev/null; then 
        version=$(docker exec "$container_name" cat /app/VERSION 2>/dev/null | tr -d '\n\r'); 
        if [ -n "$version" ]; then echo "$version"; return; fi; 
    fi; 
    # Фолбэк
    echo "latest"; 
}

scan_server_state() { 
    SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён"; 
    
    # Проверка на Docker
    if command -v docker &>/dev/null; then
        if docker ps --format '{{.Names}}' | grep -q "^remnawave$"; then SERVER_TYPE="Панель"; local pnc="remnawave"; elif docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then SERVER_TYPE="Нода"; local pnc="remnanode"; fi; 
        if [ -n "${pnc:-}" ]; then PANEL_NODE_PATH=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$pnc" 2>/dev/null); PANEL_NODE_VERSION=$(get_docker_version "$pnc"); fi; 
        
        local bot_container_name="remnawave_bot"; 
        if docker ps --format '{{.Names}}' | grep -q "^${bot_container_name}$"; then 
            BOT_DETECTED=1; 
            local bot_cp; bot_cp=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$bot_container_name" 2>/dev/null || true); 
            if [ -n "$bot_cp" ]; then BOT_PATH=$(dirname "$bot_cp"); fi
            BOT_VERSION=$(get_docker_version "$bot_container_name"); 
        fi
        
        if docker ps --format '{{.Names}}' | grep -q "remnawave-nginx"; then local nv; nv=$(docker exec remnawave-nginx nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"); WEB_SERVER="Nginx $nv (Docker)"; 
        elif docker ps --format '{{.Names}}' | grep -q "caddy"; then local cv; cv=$(docker exec caddy caddy version 2>/dev/null | cut -d' ' -f1 || echo "unknown"); WEB_SERVER="Caddy $cv (Docker)"; fi
    fi

    if [[ "$WEB_SERVER" == "Не определён" ]] && command -v ss &>/dev/null; then
        if ss -tlpn | grep -q -E 'nginx|caddy|apache2|httpd'; then WEB_SERVER="Web-сервер (на хосте)"; fi
    fi
}

get_cpu_info() { lscpu | grep "Model name" | sed 's/.*Model name:[[:space:]]*//' | sed 's/ @.*//'; }
get_cpu_load() { echo "$(uptime | awk -F'load average: ' '{print $2}' | cut -d, -f1) / $(nproc) ядер"; }
get_ram_info() { free -m | grep Mem | awk '{printf "%.1f/%.1f GB", $3/1024, $2/1024}'; }
get_disk_info() { df -h / | awk 'NR==2 {print $3 "/" $2}'; }
get_hoster_info() { curl -s --connect-timeout 2 ipinfo.io/org || echo "Не определён"; }

# ============================================================ #
#                       ОСНОВНЫЕ МОДУЛИ                        #
# ============================================================ #
apply_bbr() { 
    log "Запуск настройки BBR..."
    
    # Проверка на виртуализацию (в OpenVZ/LXC часто нельзя менять ядро)
    if systemd-detect-virt 2>/dev/null | grep -qE 'lxc|openvz|docker'; then
        printf "%b\n" "${C_YELLOW}⚠️ Внимание: обнаружена виртуализация ($(systemd-detect-virt)).${C_RESET}"
        printf "%b\n" "   Скорее всего, ядро общее с хостом, и поменять алгоритм не выйдет."
        read -p "   Всё равно попробовать? (y/n): " try_virt
        if [[ "$try_virt" != "y" ]]; then return; fi
    fi

    local net_status; net_status=$(get_net_status); 
    echo "--- ДИАГНОСТИКА ---"; echo "Алгоритм: $(echo "$net_status" | cut -d'|' -f1)"; echo "Планировщик: $(echo "$net_status" | cut -d'|' -f2)"; echo "-------------------"; 
    
    read -p "   Врубаем форсаж (BBR + FQ/CAKE)? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"
    
    # Бэкап не нужен, мы пишем в свой файл. Чистим старое.
    rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf
    
    # Определяем лучший доступный вариант
    local preferred_qdisc="fq"
    if modprobe sch_cake &>/dev/null; then preferred_qdisc="cake"; fi
    
    echo "# === КОНФИГ ОТ РЕШАЛЫ ===
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = $preferred_qdisc
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216" > "$CONFIG_SYSCTL"

    if sysctl -p "$CONFIG_SYSCTL" >/dev/null 2>&1; then
         printf "%b\n" "${C_GREEN}✅ Успешно применено! (BBR + $preferred_qdisc)${C_RESET}"
         log "BBR конфиг применен."
    else
         printf "%b\n" "${C_RED}❌ Ошибка применения sysctl. Возможно, ядро заблокировано хостером.${C_RESET}"
         log "Ошибка sysctl."
    fi
}

ipv6_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Назад...${C_RESET}"; sleep 1; return' INT
    while true; do
        clear; echo "--- IPv6 ---"; 
        if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" -eq 1 ]; then echo "Статус: ОТКЛЮЧЕН"; else echo "Статус: ВКЛЮЧЕН"; fi
        echo "   1. Отключить IPv6"; echo "   2. Включить IPv6"; echo "   b. Назад"; 
        read -r -p "Выбор: " choice || continue
        case $choice in 
            1) echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/98-reshala-ipv6.conf; sysctl -p /etc/sysctl.d/98-reshala-ipv6.conf >/dev/null; echo "✅ Выключено."; sleep 1;;
            2) rm -f /etc/sysctl.d/98-reshala-ipv6.conf; sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null; echo "✅ Включено."; sleep 1;;
            [bB]) break;; 
        esac
    done
    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

# ПРОСМОТР ЛОГОВ
view_logs_realtime() { 
    local log_path="$1"; local log_name="$2"; 
    [ ! -f "$log_path" ] && touch "$log_path"
    echo "[*] Журнал '$log_name' (CTRL+C для выхода)..."
    local original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_GREEN}✅ Выход...${C_RESET}"; return' INT
    
    tail -f -n 50 "$log_path" | awk -v CY="$C_YELLOW" -v CR="$C_RESET" '{print CY $1 CR "  " $2}'
    
    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

view_docker_logs() { 
    local service_path="$1"; local service_name="$2"; 
    if [ ! -f "$service_path" ]; then printf "%b\n" "❌ Нет конфига."; sleep 1; return; fi
    echo "[*] Логи '$service_name' (CTRL+C для выхода)..."
    local original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_GREEN}✅ Выход...${C_RESET}"; return' INT
    
    (cd "$(dirname "$service_path")" && docker compose logs -f) || true
    
    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

# ============================================================ #
#                       МОДУЛЬ БЕЗОПАСНОСТИ                      #
# ============================================================ #
_ensure_package_installed() {
    local package_name="$1"
    if ! command -v "$package_name" &> /dev/null; then
        printf "%b\n" "${C_YELLOW}Ставлю утилиту '${package_name}'...${C_RESET}"
        if [ -f /etc/debian_version ]; then apt-get update -qq && apt-get install -y -qq "$package_name" >/dev/null
        elif [ -f /etc/redhat-release ]; then yum install -y -q "$package_name" >/dev/null
        else printf "%b\n" "${C_RED}Не могу поставить '$package_name'. Ставь сам.${C_RESET}"; return 1; fi
    fi
}

_ssh_add_keys() {
    local original_trap; original_trap=$(trap -p INT)
    # ВАЖНО: Гарантируем удаление временного файла при любом выходе
    trap 'rm -f "${SERVERS_FILE_PATH:-}"; printf "\n%b\n" "${C_RED}Отмена.${C_RESET}"; sleep 1; return 1' INT
    
    clear; printf "%b\n" "${C_CYAN}--- ДОБАВЛЕНИЕ SSH-КЛЮЧЕЙ ---${C_RESET}"
    
    # 1. Получение ключа
    read -p "Вставь свой PUBLIC KEY (ssh-ed25519...): " PUBKEY || return 1
    if ! [[ "$PUBKEY" =~ ^ssh-(rsa|dss|ed25519|ecdsa) ]]; then printf "\n%b\n" "${C_RED}❌ Это не ключ.${C_RESET}"; sleep 2; return; fi

    # 2. Создание временного файла (Безопасно!)
    local SERVERS_FILE_PATH; SERVERS_FILE_PATH=$(mktemp /tmp/reshala_servers.XXXXXX)
    
    cat << 'EOL' > "$SERVERS_FILE_PATH"
# Впиши серверы (формат: user@ip пароль)
# root@1.2.3.4 MyP@ssw0rd
# root@5.6.7.8:2222 SecretPass
# Строки с # игнорируются
EOL

    # 3. Редактирование
    _ensure_package_installed "nano" || return
    nano "$SERVERS_FILE_PATH"
    
    if [ ! -s "$SERVERS_FILE_PATH" ]; then echo "Пустой список."; rm -f "$SERVERS_FILE_PATH"; return; fi

    _ensure_package_installed "sshpass" || return
    local TEMP_KEY_FILE; TEMP_KEY_FILE=$(mktemp); echo "$PUBKEY" > "$TEMP_KEY_FILE"

    # 4. Обработка
    printf "\n%b\n" "${C_BOLD}Погнали...${C_RESET}"
    while read -r -a parts; do
        [[ -z "${parts[0]:-}" ]] || [[ "${parts[0]}" =~ ^# ]] && continue
        local target="${parts[0]}"
        local pass="${parts[*]:1}" # Весь остаток строки - пароль (с пробелами)
        
        # Парсинг порта user@host:port
        local port_arg=""; local ssh_host="$target"
        if [[ "$target" == *":"* ]]; then
            local host_clean="${target%:*}"
            local port_clean="${target##*:}"
            ssh_host="$host_clean"
            port_arg="-p $port_clean"
        fi

        printf "➡️  %s ... " "$target"
        
        if [ -n "$pass" ]; then
            if sshpass -p "$pass" ssh-copy-id -i "$TEMP_KEY_FILE" $port_arg -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$ssh_host" &>/dev/null; then
                printf "%b\n" "${C_GREEN}OK${C_RESET}"
            else
                printf "%b\n" "${C_RED}FAIL (Пароль? SSH порт?)${C_RESET}"
            fi
        else
             printf "%b\n" "${C_YELLOW}SKIP (Нет пароля)${C_RESET}"
        fi

    done < "$SERVERS_FILE_PATH"

    # 5. Чистка
    rm -f "$SERVERS_FILE_PATH" "$TEMP_KEY_FILE"
    printf "\n%b\n" "${C_GREEN}✅ Готово. Список серверов удалён.${C_RESET}"
    wait_for_enter

    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

security_menu() {
    while true; do
        clear; echo "--- БЕЗОПАСНОСТЬ ---"; 
        echo "   1. Раскидать SSH-ключи (Mass Deploy)"; echo "   b. Назад"; 
        read -r -p "Выбор: " choice || continue
        case $choice in 1) _ssh_add_keys;; [bB]) break;; esac
    done
}

# ============================================================ #
#                   ОБНОВЛЕНИЕ СИСТЕМЫ                         #
# ============================================================ #
system_update_wizard() {
    if ! command -v apt &> /dev/null; then echo "Только для Debian/Ubuntu."; sleep 2; return; fi
    clear; echo "🚀 ПОЛНОЕ ОБНОВЛЕНИЕ..."; echo ""
    read -p "Запустить (update+upgrade+autoremove)? (y/n): " c
    if [[ "$c" == "y" ]]; then
        apt update && apt full-upgrade -y && apt autoremove -y && apt autoclean
        save_path "LAST_SYS_UPDATE" "$(date +%Y%m%d)"
        printf "\n%b\n" "${C_GREEN}✅ Система блестит.${C_RESET}"; wait_for_enter
    fi
}

offer_initial_update() {
    local last; last=$(load_path "LAST_SYS_UPDATE")
    if [ "$last" != "$(date +%Y%m%d)" ]; then system_update_wizard; fi
}

uninstall_script() {
    read -p "Сносим Решалу? (y/n): " c; if [[ "$c" != "y" ]]; then return; fi
    rm -f "$INSTALL_PATH" "$CONFIG_FILE" "$LOGFILE"
    sed -i "/alias reshala=/d" /root/.bashrc
    echo "✅ Убит. Перезайди в терминал."; exit 0
}

# ============================================================ #
#                   ГЛАВНОЕ МЕНЮ                               #
# ============================================================ #
show_menu() {
    trap 'printf "\n%b\n" "${C_YELLOW}Выход через меню [q]!${C_RESET}"; sleep 1' INT
    while true; do
        scan_server_state
        check_for_updates
        
        # Хедер
        clear; printf "%b\n" "${C_CYAN}╔═[ РЕШАЛА ${VERSION} ]═══════════════════════════════╗${C_RESET}"
        printf "║ IP: ${C_YELLOW}%-15s${C_RESET} CPU: %-20s ║\n" "$(hostname -I | awk '{print $1}')" "$(get_cpu_load)"
        printf "║ RAM: %-15s DISK: %-19s ║\n" "$(get_ram_info)" "$(get_disk_info)"
        if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then printf "║ APP: ${C_GREEN}%-15s${C_RESET} VER: %-20s ║\n" "$SERVER_TYPE" "${PANEL_NODE_VERSION:0:15}"; fi
        printf "%b\n" "${C_CYAN}╚═══════════════════════════════════════════════════╝${C_RESET}"

        echo "   [0] 🔄 Обновить OS (apt)"
        echo "   [1] 🚀 Ускорение (BBR)"
        echo "   [2] 🌐 Настройка IPv6"
        echo "   [3] 📜 Журнал скрипта"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo "   [4] 🤖 Логи Бота"; fi
        if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then echo "   [5] 📊 Логи Панели/Ноды"; fi
        printf "   [6] %b\n" "🛡️  SSH Ключи (Deployer)"

        if [[ ${UPDATE_AVAILABLE} -eq 1 ]]; then printf "   [u] %b\n" "‼️ ОБНОВИТЬ СКРИПТ ‼️"; fi
        echo ""; echo "   [d] 🗑️ Удалить"; echo "   [q] 🚪 Выход"
        
        read -r -p ">> " choice || continue
        case $choice in
            0) system_update_wizard;;
            1) apply_bbr; wait_for_enter;;
            2) ipv6_menu;;
            3) view_logs_realtime "$LOGFILE" "Решалы";;
            4) [ "$BOT_DETECTED" -eq 1 ] && view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота";;
            5) [ -n "$PANEL_NODE_PATH" ] && view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE";;
            6) security_menu;;
            [uU]) [ ${UPDATE_AVAILABLE} -eq 1 ] && run_update;;
            [dD]) uninstall_script;;
            [qQ]) echo "Бывай. 👋"; exit 0;;
        esac
    done
}

# ============================================================ #
#                       ТОЧКА ВХОДА                            #
# ============================================================ #
main() {
    # Проверка прав root
    if [[ $EUID -ne 0 ]]; then 
        printf "%b\n" "${C_RED}❌ Запускай через sudo!${C_RESET}"
        exit 1
    fi

    # Инициализация лога
    if [ ! -f "$LOGFILE" ]; then touch "$LOGFILE" && chmod 666 "$LOGFILE"; fi
    log "Запуск $VERSION"

    if [[ "${1:-}" == "install" ]]; then
        install_script
    else
        trap "rm -f /tmp/reshala_*" EXIT # Глобальная зачистка мусора
        offer_initial_update
        show_menu
    fi
}

main "$@"