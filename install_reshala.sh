#!/bin/bash
# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v2.21139 - FIXED & POLISHED   ==
# ============================================================ #
set -uo pipefail

# ============================================================ #
#                  КОНСТАНТЫ И ПЕРЕМЕННЫЕ                      #
# ============================================================ #
readonly VERSION="v2.21139"
# Убедись, что ветка (dev/main) правильная!
readonly REPO_BRANCH="dev" 
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/${REPO_BRANCH}/install_reshala.sh"
readonly MODULES_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/${REPO_BRANCH}/modules"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala.log"
INSTALL_PATH="/usr/local/bin/reshala"

# --- Цвета для вывода в терминал ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_GRAY='\033[0;90m'
C_WHITE='\033[1;37m'

# --- Глобальные переменные состояния ---
SERVER_TYPE="Чистый сервак"
PANEL_VERSION=""
NODE_VERSION=""
PANEL_NODE_PATH=""
BOT_DETECTED=0
BOT_VERSION=""
BOT_PATH=""
WEB_SERVER="Не определён"
UPDATE_AVAILABLE=0
LATEST_VERSION=""
UPDATE_CHECK_STATUS="OK"

# ============================================================ #
#                     УТИЛИТАРНЫЕ ФУНКЦИИ                      #
# ============================================================ #

run_module() {
    local module_name="$1"
    local module_url="${MODULES_URL}/${module_name}"
    local temp_file="/tmp/${module_name}"

    printf "%b\n" "${C_CYAN}☁️ Загружаю модуль ${module_name} из облака...${C_RESET}"
    
    # Скачиваем модуль
    if curl -s -L --fail "$module_url" -o "$temp_file"; then
        chmod +x "$temp_file"
        log "Запуск модуля: $module_name"
        # Запускаем
        bash "$temp_file"
        # Удаляем после выполнения
        rm -f "$temp_file"
    else
        printf "%b\n" "${C_RED}❌ Ошибка загрузки модуля. Проверь интернет или наличие файла в репозитории.${C_RESET}"
        log "Ошибка загрузки модуля $module_name с $module_url"
        sleep 2
    fi
}

# Запуск команд с sudo, если нужно
run_cmd() { 
    if [[ $EUID -eq 0 ]]; then 
        "$@"
    else 
        sudo "$@"
    fi
}

# Простая и надежная функция лога (как в v1.92)
log() { 
    # Если файла нет, создаем его и даем права (на всякий случай)
    if [ ! -f "$LOGFILE" ]; then 
        run_cmd touch "$LOGFILE"
        run_cmd chmod 666 "$LOGFILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | run_cmd tee -a "$LOGFILE" > /dev/null
}

# Ожидание нажатия Enter
wait_for_enter() { 
    read -p $'
Нажми Enter, чтобы продолжить...'
}

# Сохранение переменных в конфиг
save_path() { 
    local key="$1"
    local value="$2"
    touch "$CONFIG_FILE"
    sed -i "/^$key=/d" "$CONFIG_FILE"
    echo "$key=\"$value\"" >> "$CONFIG_FILE"
}

# Загрузка переменных из конфига
load_path() { 
    local key="$1"
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" &>/dev/null
    eval echo "\${$key:-}"
}

# Получение статуса сети (BBR/Queue)
get_net_status() { 
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")
    local qdisc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a")
    
    if [ -z "$qdisc" ] || [ "$qdisc" = "pfifo_fast" ]; then 
        qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n 1) || qdisc="n/a"
    fi
    echo "$cc|$qdisc"
}

# === НОВЫЕ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ V4 (СЕТЬ И ВЫРАВНИВАНИЕ) ===

_ensure_net_tools() {
    if ! command -v ethtool &>/dev/null; then
        # Тихая установка ethtool для определения скорости порта
        run_cmd apt-get update -qq && run_cmd apt-get install -y -qq ethtool >/dev/null 2>&1
    fi
}

get_port_speed() {
    # Пытаемся узнать, какой кабель воткнут (1Gbps, 10Gbps и т.д.)
    local iface
    iface=$(ip route | grep default | head -n1 | awk '{print $5}')
    
    local speed=""
    
    # Способ 1: cat /sys/class/net/...
    if [ -f "/sys/class/net/$iface/speed" ]; then
        local raw_speed
        raw_speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
        # Если скорость валидная и больше 0
        if [[ "$raw_speed" =~ ^[0-9]+$ ]] && [ "$raw_speed" -gt 0 ]; then
            speed="${raw_speed}Mbps"
        fi
    fi
    
    # Способ 2: ethtool (если первый не сработал)
    if [ -z "$speed" ] && command -v ethtool &>/dev/null; then
        speed=$(ethtool "$iface" 2>/dev/null | grep "Speed:" | awk '{print $2}')
    fi
    
    # Красивое форматирование
    if [ "$speed" == "1000Mbps" ]; then speed="1 Gbps"; fi
    if [ "$speed" == "10000Mbps" ]; then speed="10 Gbps"; fi
    if [ "$speed" == "2500Mbps" ]; then speed="2.5 Gbps"; fi
    
    echo "${speed:-Virtual Port}"
}

run_speedtest_moscow() {
    clear
    printf "%b\n" "${C_CYAN}🚀 ЗАПУСКАЮ ТЕСТ СКОРОСТИ ДО МОСКВЫ...${C_RESET}"
    echo "   (Используем официальный speedtest-cli, сервер MTS/Megafon/Beeline)"
    
    if ! command -v speedtest-cli &>/dev/null; then
        echo "   Installing speedtest-cli..."
        run_cmd apt-get update -qq
        run_cmd apt-get install -y speedtest-cli >/dev/null
    fi
    
    echo ""
    # ID серверов в Москве: 
    # 11599 - MTS (Moscow)
    # 16976 - Beeline (Moscow)
    # 22157 - Rostelecom (Moscow)
    # Используем Beeline как стабильный
    printf "%b\n" "${C_YELLOW}⏳ Измеряю... Не дёргайся.${C_RESET}"
    speedtest-cli --server 16976 --simple
    
    echo ""
    printf "%b\n" "${C_GREEN}✅ Тест завершён.${C_RESET}"
    wait_for_enter
}
# Проверяет, относится ли имя контейнера к экосистеме Remnawave
is_remnawave_container() {
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

# Очистка версии от лишних символов (v, пробелы)
clean_version() {
    local v="$1"
    # Убираем 'v' в начале (регистронезависимо), убираем пробелы
    echo "$v" | sed 's/^[vV]//' | tr -d '[:space:]'
}

# Извлекает версию ноды и Xray из логов (FIXED EDITION)
get_node_version_from_logs() {
    local container="$1"
    # Читаем последние 10000 строк, чтобы точно найти момент запуска, если логов много
    local logs
    logs=$(run_cmd docker logs --tail 10000 "$container" 2>&1)
    
    # Ищем версию Ноды (обычно "Remnawave Node v1.2.3")
    local node_ver
    node_ver=$(echo "$logs" | grep -oE "Remnawave Node v[0-9.]+" | tail -n 1 | sed 's/Remnawave Node //')
    
    # Ищем версию Xray. Варианты бывают разные, ищем гибко.
    local xray_ver
    # Попытка 1: "Xray-core v1.8.24"
    xray_ver=$(echo "$logs" | grep -oE "Xray-core v[0-9.]+" | tail -n 1 | sed 's/Xray-core //')
    
    # Попытка 2: Если не нашли, ищем "XRay Core: v1.8.24" (как в некоторых сборках)
    if [ -z "$xray_ver" ]; then
        xray_ver=$(echo "$logs" | grep -oE "XRay Core: v[0-9.]+" | tail -n 1 | sed 's/XRay Core: //')
    fi

    # Формируем красивый вывод
    if [ -n "$node_ver" ]; then
        if [ -n "$xray_ver" ]; then
            echo "${node_ver} (Xray: ${xray_ver})"
        else
            echo "${node_ver}"
        fi
    else
        # Если даже в логах ни хрена нет
        echo "latest (не нашёл в логах)"
    fi
}

# Извлекает версию панели, сканируя логи
get_panel_version_from_logs() {
    local container_names
    container_names=$(run_cmd docker ps --format '{{.Names}}' 2>/dev/null | grep "^remnawave-")
    
    if [ -z "$container_names" ]; then
        echo "latest"
        return
    fi

    local name
    while IFS= read -r name; do
        # Пропускаем вспомогательные контейнеры, которые не логируют версию
        case "$name" in
            *-nginx|*-redis|*-db|*-bot|*-scheduler|*-processor|*-subscription-page|*-telegram-mini-app|*-tinyauth)
                continue
                ;;
        esac

        # Проверяем логи этого контейнера (обычно backend)
        local logs
        logs=$(run_cmd docker logs "$name" 2>/dev/null | tail -n 150)
        local panel_ver
        panel_ver=$(echo "$logs" | grep -oE 'Remnawave Backend v[0-9.]*' | head -n1 | sed 's/Remnawave Backend v//')
        
        if [ -n "$panel_ver" ]; then
            echo "${panel_ver}"
            return
        fi
    done <<< "$container_names"

    # Fallback: subscription-page (если основной бэкенд не найден или молчит)
    if run_cmd docker ps --format '{{.Names}}' | grep -q "remnawave-subscription-page"; then
        local sub_ver
        sub_ver=$(run_cmd docker logs remnawave-subscription-page 2>/dev/null | grep -oE 'Remnawave Subscription Page v[0-9.]*' | head -n1 | sed 's/Remnawave Subscription Page v//')
        if [ -n "$sub_ver" ]; then
            echo "${sub_ver} (sub-page)"
            return
        fi
    fi

    echo "latest"
}

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

# === НОВЫЕ ФУНКЦИИ ДЛЯ DASHBOARD v3.0 (GRAPHIC EDITION) ===

# --- УЛУЧШЕННАЯ ЧИСТКА ИМЕНИ CPU ---
get_cpu_info_clean() {
    local model
    # Берем из /proc/cpuinfo
    model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)
    
    # Если пусто, пробуем lscpu
    if [ -z "$model" ]; then
        model=$(lscpu | grep "Model name" | head -n 1 | cut -d: -f2)
    fi

    # Чистка: убираем (R), (TM), частоту (@ 2.40GHz), лишние пробелы
    # Но ОСТАВЛЯЕМ бренды (Intel, AMD, Ryzen, Xeon)
    echo "$model" | sed 's/(R)//g; s/(TM)//g; s/ @.*//g; s/CPU//g; s/Processor//g; s/Compute Engine//g' | xargs
}

# --- УНИВЕРСАЛЬНАЯ РИСОВАЛКА БАРОВ ---
draw_bar() {
    local perc=$1
    local size=10
    
    # Защита от дурака (если > 100%)
    local bar_perc=$perc
    [ "$bar_perc" -gt 100 ] && bar_perc=100
    
    local filled=$(( bar_perc * size / 100 ))
    local empty=$(( size - filled ))
    
    # Цвет: Зеленый < 70% < Желтый < 90% < Красный
    local color="${C_GREEN}"
    [ "$perc" -ge 70 ] && color="${C_YELLOW}"
    [ "$perc" -ge 90 ] && color="${C_RED}"
    
    printf "${C_GRAY}["
    printf "${color}"
    for ((i=0; i<filled; i++)); do printf "■"; done
    printf "${C_GRAY}"
    for ((i=0; i<empty; i++)); do printf "□"; done
    printf "${C_GRAY}] ${color}%3s%%${C_RESET}" "$perc"
}

# --- RAM С БАРОМ И ТОЧНЫМИ ЦИФРАМИ ---
get_ram_visual() {
    local ram_used; ram_used=$(free -m | grep Mem | awk '{print $3}')
    local ram_total; ram_total=$(free -m | grep Mem | awk '{print $2}')
    
    # Защита от деления на ноль
    if [ "$ram_total" -eq 0 ]; then echo "N/A"; return; fi
    
    local perc=$(( 100 * ram_used / ram_total ))
    local bar; bar=$(draw_bar "$perc")
    
    # Красивые цифры (GB если много, MB если мало)
    local used_str; local total_str
    if [ "$ram_total" -gt 1024 ]; then
        used_str=$(awk "BEGIN {printf \"%.1fG\", $ram_used/1024}")
        total_str=$(awk "BEGIN {printf \"%.1fG\", $ram_total/1024}")
    else
        used_str="${ram_used}M"
        total_str="${ram_total}M"
    fi
    
    echo "$bar ($used_str / $total_str)"
}

# --- ДИСК С БАРОМ ---
get_disk_visual() {
    local root_device; root_device=$(df / | awk 'NR==2 {print $1}')
    local main_disk; main_disk=$(lsblk -no pkname "$root_device" 2>/dev/null || basename "$root_device" | sed 's/[0-9]*$//')
    
    # Тип диска
    local disk_type="HDD"
    if [ -f "/sys/block/$main_disk/queue/rotational" ]; then 
        if [ "$(cat "/sys/block/$main_disk/queue/rotational")" -eq 0 ]; then disk_type="SSD"; fi
    elif [[ "$main_disk" == *"nvme"* ]]; then disk_type="SSD"; fi

    # Цифры
    local used; used=$(df -h / | awk 'NR==2 {print $3}')
    local total; total=$(df -h / | awk 'NR==2 {print $2}')
    local perc_str; perc_str=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    
    local bar; bar=$(draw_bar "$perc_str")
    
    # Возвращаем: TYPE|STRING  (чтобы разделить в display_header)
    echo "$disk_type|$bar ($used / $total)"
}

# --- НАГРУЗКА CPU С БАРОМ ---
get_cpu_load_visual() {
    local cores; cores=$(nproc)
    local load; load=$(uptime | awk -F'load average: ' '{print $2}' | cut -d, -f1 | xargs)
    
    # Считаем процент нагрузки (Load / Cores * 100)
    local perc
    perc=$(awk "BEGIN {printf \"%.0f\", ($load / $cores) * 100}")
    
    local bar; bar=$(draw_bar "$perc")
    
    echo "$bar ($load / $cores vCore)"
}

get_location() {
    # Получаем страну (Code), например FI
    local country
    country=$(curl -s --connect-timeout 2 ipinfo.io/country 2>/dev/null || echo "UNK")
    echo "$country"
}

get_active_users() {
    # Считаем уникальных юзеров
    local count
    count=$(who | cut -d' ' -f1 | sort | uniq | wc -l)
    echo "$count"
}

get_docker_version() { 
    local container_name="$1"
    local version=""
    
    # Метод 1: Labels
    version=$(run_cmd docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$container_name" 2>/dev/null)
    if [ -n "$version" ]; then echo "$version"; return; fi
    
    # Метод 2: ENV
    version=$(run_cmd docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null | grep -E '^(APP_VERSION|VERSION)=' | head -n 1 | cut -d'=' -f2)
    if [ -n "$version" ]; then echo "$version"; return; fi
    
    # Метод 3: package.json
    if run_cmd docker exec "$container_name" test -f /app/package.json 2>/dev/null; then 
        version=$(run_cmd docker exec "$container_name" cat /app/package.json 2>/dev/null | jq -r .version 2>/dev/null)
        if [ -n "$version" ] && [ "$version" != "null" ]; then echo "$version"; return; fi
    fi
    
    # Метод 4: Файл VERSION
    if run_cmd docker exec "$container_name" test -f /app/VERSION 2>/dev/null; then 
        version=$(run_cmd docker exec "$container_name" cat /app/VERSION 2>/dev/null | tr -d '
\r')
        if [ -n "$version" ]; then echo "$version"; return; fi
    fi
    
    # Fallback: Тег образа
    local image_tag
    image_tag=$(run_cmd docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2)
    if [ -n "$image_tag" ] && [ "$image_tag" != "latest" ]; then echo "$image_tag"; return; fi
    
    local image_id
    image_id=$(run_cmd docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2)
    echo "latest (образ: ${image_id:0:7})"
}
# === НОВЫЕ ФУНКЦИИ ДЛЯ DASHBOARD v2.0 ===

get_os_ver() {
    if [ -f /etc/os-release ]; then
        # Вытаскиваем красивое имя, например "Ubuntu 22.04.3 LTS"
        grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release | head -n 1
    else
        echo "Linux (Unknown)"
    fi
}

get_kernel() {
    uname -r | cut -d'-' -f1  # Показываем только версию ядра, без лишнего мусора
}

get_uptime() {
    # Красивый аптайм: "2 days, 4 hours" или "15 min"
    uptime -p | sed 's/up //;s/ hours\?,/ч/;s/ minutes\?/мин/;s/ days\?,/д/;s/ weeks\?,/нед/'
}

get_virt_type() {
    local virt
    virt=$(systemd-detect-virt 2>/dev/null)
    if [ "$virt" == "kvm" ] || [ "$virt" == "qemu" ]; then
        echo "KVM (Честное железо)"
    elif [ "$virt" == "lxc" ] || [ "$virt" == "openvz" ]; then
        echo "Container ($virt) - ⚠️"
    elif [ "$virt" == "none" ]; then
        echo "Bare Metal (Дед)"
    else
        echo "${virt:-Unknown}"
    fi
}

get_ping_google() {
    # Пинг до гугла, берем среднее значение. Быстро, дерзко.
    local p
    p=$(ping -c 1 -W 1 8.8.8.8 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | cut -d' ' -f1)
    if [ -z "$p" ]; then
        echo "OFFLINE ❌"
    else
        echo "${p} ms ⚡"
    fi
}

# УЛУЧШЕННАЯ версия CPU (чистит мусор RHEL/QEMU)
get_cpu_info() { 
    local model
    model=$(lscpu | grep "Model name" | sed 's/.*Model name:[[:space:]]*//' | sed 's/ @.*//')
    # Если lscpu выдал дичь типа "QEMU Virtual CPU", пробуем /proc/cpuinfo
    if [[ "$model" == *"QEMU"* ]] || [[ "$model" == *"Common KVM"* ]] || [ -z "$model" ]; then
        model=$(cat /proc/cpuinfo | grep 'model name' | head -n 1 | cut -d: -f2 | xargs)
    fi
    # Если всё ещё пусто или мусор
    if [ -z "$model" ]; then model="Unknown CPU"; fi
    
    # Обрезаем слишком длинные названия, чтобы не ломать таблицу
    echo "$model" | cut -c 1-35
}

# УЛУЧШЕННАЯ версия RAM + SWAP
get_ram_swap_info() {
    local ram_used; ram_used=$(free -m | grep Mem | awk '{print $3}')
    local ram_total; ram_total=$(free -m | grep Mem | awk '{print $2}')
    local swap_used; swap_used=$(free -m | grep Swap | awk '{print $3}')
    
    # Конвертируем в ГБ, если больше 1024МБ, иначе в МБ
    local ram_str
    if [ "$ram_total" -gt 1024 ]; then
        ram_str=$(awk "BEGIN {printf \"%.1f/%.1f GB\", $ram_used/1024, $ram_total/1024}")
    else
        ram_str="${ram_used}/${ram_total} MB"
    fi

    if [ "$swap_used" -ne 0 ]; then
        echo "$ram_str (Swap: ${swap_used}MB)"
    else
        echo "$ram_str"
    fi
}
scan_server_state() { 
    # Сброс переменных перед сканированием
    SERVER_TYPE="Чистый сервак"
    PANEL_VERSION=""
    NODE_VERSION=""
    PANEL_NODE_PATH=""
    BOT_DETECTED=0
    BOT_VERSION=""
    BOT_PATH=""
    WEB_SERVER="Не определён"

    # Получаем список имён контейнеров
    local container_names
    container_names=$(run_cmd docker ps --format '{{.Names}}' 2>/dev/null)
    
    # Если контейнеров нет вообще
    if [ -z "$container_names" ]; then
        SERVER_TYPE="Чистый сервак"
        return
    fi

    local is_panel=0
    local is_node=0
    local has_foreign=0
    
    # Временные переменные для имен контейнеров (чтобы вытащить версию)
    local panel_container=""
    local node_container=""

    # Анализ запущенных контейнеров
    while IFS= read -r name; do
        # --- ОПРЕДЕЛЕНИЕ ПАНЕЛИ ---
        # Панель считаем найденной ТОЛЬКО если есть backend или subscription-page.
        # Просто remnawave-nginx может быть и на ноде (теоретически), или остатком.
        if [[ "$name" == "remnawave-backend"* ]] || [[ "$name" == "remnawave-subscription-page"* ]]; then
            is_panel=1
            # Предпочитаем backend для извлечения пути
            if [[ "$name" == *"backend"* ]]; then
                panel_container="$name"
            elif [ -z "$panel_container" ]; then
                panel_container="$name"
            fi
        
        # --- ОПРЕДЕЛЕНИЕ НОДЫ ---
        elif [[ "$name" == "remnanode"* ]]; then
            is_node=1
            node_container="$name"
            
        # --- ОПРЕДЕЛЕНИЕ БОТА ---
        elif [[ "$name" == "remnawave_bot" ]]; then
            # Бот обрабатывается отдельно ниже, не влияет на тип сервера (Панель/Нода)
            :
            
        # --- ОСТАЛЬНЫЕ КОНТЕЙНЕРЫ ---
        else
            # Если это remnawave-контейнер (например nginx), но не backend/node/bot,
            # мы его игнорируем для определения ТИПА, но он не считается "чужим".
            if ! is_remnawave_container "$name"; then
                has_foreign=1
            fi
        fi
    done <<< "$container_names"

    # --- ЛОГИКА ОПРЕДЕЛЕНИЯ ТИПА СЕРВЕРА ---
    
    if [ $is_panel -eq 1 ] && [ $is_node -eq 1 ]; then
        SERVER_TYPE="Панель и Нода"
        
        # Обработка Панели
        PANEL_NODE_PATH=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$panel_container" 2>/dev/null)
        local raw_p_ver=$(get_panel_version_from_logs)
        PANEL_VERSION=$(clean_version "$raw_p_ver")

        # Обработка Ноды
        local raw_n_ver=$(get_node_version_from_logs "$node_container")
        NODE_VERSION=$(clean_version "$raw_n_ver")

    elif [ $is_panel -eq 1 ]; then
        SERVER_TYPE="Панель"
        PANEL_NODE_PATH=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$panel_container" 2>/dev/null)
        local raw_p_ver=$(get_panel_version_from_logs)
        PANEL_VERSION=$(clean_version "$raw_p_ver")

    elif [ $is_node -eq 1 ]; then
        SERVER_TYPE="Нода"
        PANEL_NODE_PATH=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$node_container" 2>/dev/null)
        local raw_n_ver=$(get_node_version_from_logs "$node_container")
        NODE_VERSION=$(clean_version "$raw_n_ver")

    elif [ $has_foreign -eq 1 ]; then
        SERVER_TYPE="Сервак не целка"
    else
        # Контейнеры есть, но только бот или что-то неопознанное из системы (но не чужое)
        SERVER_TYPE="Чистый сервак"
    fi

    # --- ОБНАРУЖЕНИЕ БОТА (НЕЗАВИСИМО ОТ ТИПА) ---
    if echo "$container_names" | grep -q "^remnawave_bot$"; then
        BOT_DETECTED=1
        local bot_compose_path
        bot_compose_path=$(run_cmd docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "remnawave_bot" 2>/dev/null || true)
        if [ -n "$bot_compose_path" ]; then
            BOT_PATH=$(dirname "$bot_compose_path")
            if [ -f "$BOT_PATH/VERSION" ]; then
                BOT_VERSION=$(cat "$BOT_PATH/VERSION")
            else
                BOT_VERSION=$(get_docker_version "remnawave_bot")
            fi
        else
            BOT_VERSION=$(get_docker_version "remnawave_bot")
        fi
        BOT_VERSION=$(clean_version "$BOT_VERSION")
    fi

    # --- ОПРЕДЕЛЕНИЕ ВЕБ-СЕРВЕРА ---
    if echo "$container_names" | grep -q "remnawave-nginx"; then
        local nginx_version
        nginx_version=$(run_cmd docker exec remnawave-nginx nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        WEB_SERVER="Nginx $nginx_version (в Docker)"
    elif echo "$container_names" | grep -q "caddy"; then
        local caddy_version
        caddy_version=$(run_cmd docker exec caddy caddy version 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        WEB_SERVER="Caddy $caddy_version (в Docker)"
    elif ss -tlpn | grep -q -E 'nginx|caddy|apache2|httpd'; then
        if command -v nginx &> /dev/null; then
            local nginx_version
            nginx_version=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
            WEB_SERVER="Nginx $nginx_version (на хосте)"
        else
            WEB_SERVER=$(ss -tlpn | grep -E 'nginx|caddy|apache2|httpd' | head -n 1 | sed -n 's/.*users:(("\([^"]*\)".*))/\2/p')
        fi
    fi
}

get_cpu_info() { local model; model=$(lscpu | grep "Model name" | sed 's/.*Model name:[[:space:]]*//' | sed 's/ @.*//'); echo "$model"; }
get_cpu_load() { local cores; cores=$(nproc); local load; load=$(uptime | awk -F'load average: ' '{print $2}' | cut -d, -f1); echo "$load / $cores ядер"; }
get_ram_info() { free -m | grep Mem | awk '{printf "%.1f/%.1f GB", $3/1024, $2/1024}'; }
get_disk_info() { local root_device; root_device=$(df / | awk 'NR==2 {print $1}'); local main_disk; main_disk=$(lsblk -no pkname "$root_device" 2>/dev/null || basename "$root_device" | sed 's/[0-9]*$//'); local disk_type="HDD"; if [ -f "/sys/block/$main_disk/queue/rotational" ]; then if [ "$(cat "/sys/block/$main_disk/queue/rotational")" -eq 0 ]; then disk_type="SSD"; fi; elif [[ "$main_disk" == *"nvme"* ]]; then disk_type="SSD"; fi; local usage; usage=$(df -h / | awk 'NR==2 {print $3 "/" $2}'); echo "$disk_type ($usage)"; }
get_hoster_info() { curl -s --connect-timeout 5 ipinfo.io/org || echo "Не определён"; }

# ============================================================ #
#                       ОСНОВНЫЕ МОДУЛИ                        #
# ============================================================ #
apply_bbr() { 
    log "🚀 ЗАПУСК ТУРБОНАДДУВА (BBR/CAKE)..."
    local net_status; net_status=$(get_net_status)
    local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1)
    local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2)
    local cake_available; cake_available=$(modprobe sch_cake &>/dev/null && echo "true" || echo "false")
    
    echo "--- ДИАГНОСТИКА ТВОЕГО ДВИГАТЕЛЯ ---"
    echo "Алгоритм: $current_cc"
    echo "Планировщик: $current_qdisc"
    echo "------------------------------------"
    
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then 
        printf "%b\n" "${C_GREEN}✅ Ты уже на максимальном форсаже (BBR+CAKE). Не мешай машине работать.${C_RESET}"
        log "Проверка «Форсаж»: Максимум."
        return
    fi
    
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "fq" && "$cake_available" == "true" ]]; then 
        printf "%b\n" "${C_YELLOW}⚠️ У тебя неплохо (BBR+FQ), но можно лучше. CAKE доступен.${C_RESET}"
        read -p "   Хочешь проапгрейдиться до CAKE? Это топчик. (y/n): " upgrade_confirm
        if [[ "$upgrade_confirm" != "y" && "$upgrade_confirm" != "Y" ]]; then 
            echo "Как скажешь. Остаёмся на FQ."
            log "Отказ от апгрейда до CAKE."
            return
        fi
        echo "Красава. Делаем как надо."
    elif [[ "$current_cc" != "bbr" && "$current_cc" != "bbr2" ]]; then 
        echo "Хм, ездишь на стоке. Пора залить ракетное топливо."
    fi
    
    local available_cc; available_cc=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}')
    local preferred_cc="bbr"
    if [[ "$available_cc" == *"bbr2"* ]]; then preferred_cc="bbr2"; fi
    
    local preferred_qdisc="fq"
    if [[ "$cake_available" == "true" ]]; then 
        preferred_qdisc="cake"
    else 
        log "⚠️ 'cake' не найден, ставлю 'fq'."
        modprobe sch_fq &>/dev/null
    fi
    
    local tcp_fastopen_val=0
    [[ $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0) -ge 1 ]] && tcp_fastopen_val=3
    
    local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"
    log "🧹 Чищу старое говно..."
    run_cmd rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf
    if [ -f /etc/sysctl.conf.bak ]; then run_cmd rm /etc/sysctl.conf.bak; fi
    run_cmd sed -i.bak -E 's/^[[:space:]]*(net.core.default_qdisc|net.ipv4.tcp_congestion_control)/#&/' /etc/sysctl.conf
    
    log "✍️  Устанавливаю новые, пиздатые настройки..."
    echo "# === КОНФИГ «ФОРСАЖ» ОТ РЕШАЛЫ — НЕ ТРОГАТЬ ===
net.ipv4.tcp_congestion_control = $preferred_cc
net.core.default_qdisc = $preferred_qdisc
net.ipv4.tcp_fastopen = $tcp_fastopen_val
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216" | run_cmd tee "$CONFIG_SYSCTL" > /dev/null
    
    log "🔥 Применяю настройки..."
    run_cmd sysctl -p "$CONFIG_SYSCTL" >/dev/null
    
    echo ""
    echo "--- КОНТРОЛЬНЫЙ ВЫСТРЕЛ ---"
    echo "Новый алгоритм: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "Новый планировщик: $(sysctl -n net.core.default_qdisc)"
    echo "---------------------------"
    printf "%b\n" "${C_GREEN}✅ Твоя тачка теперь — ракета. (CC: $preferred_cc, QDisc: $preferred_qdisc)${C_RESET}"
    log "BBR+CAKE успешно применены."
}

check_ipv6_status() { 
    if [ ! -d "/proc/sys/net/ipv6" ]; then 
        printf "%b" "${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"
    elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then 
        printf "%b" "${C_RED}КАСТРИРОВАН${C_RESET}"
    else 
        printf "%b" "${C_GREEN}ВКЛЮЧЁН${C_RESET}"
    fi
}

disable_ipv6() { 
    if [ ! -d "/proc/sys/net/ipv6" ]; then 
        printf "%b\n" "❌ ${C_YELLOW}Тут нечего отключать. Провайдер уже всё отрезал за тебя.${C_RESET}"
        return
    fi
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then 
        echo "⚠️ IPv6 уже кастрирован."
        return
    fi
    echo "🔪 Кастрирую IPv6... Это не больно. Почти."
    run_cmd tee /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ОТКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOL
    run_cmd sysctl -p /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null
    log "-> IPv6 кастрирован через sysctl."
    printf "%b\n" "${C_GREEN}✅ Готово. Теперь эта тачка ездит только на нормальном топливе.${C_RESET}"
}

enable_ipv6() { 
    if [ ! -d "/proc/sys/net/ipv6" ]; then 
        printf "%b\n" "❌ ${C_YELLOW}Тут нечего включать. Я не могу пришить то, что отрезано с корнем.${C_RESET}"
        return
    fi
    if [ ! -f /etc/sysctl.d/98-reshala-disable-ipv6.conf ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 0 ]; then 
        echo "✅ IPv6 и так работает. Не мешай ему."
        return
    fi
    echo "💉 Возвращаю всё как было... Реанимация IPv6."
    run_cmd rm -f /etc/sysctl.d/98-reshala-disable-ipv6.conf
    run_cmd tee /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ВКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOL
    run_cmd sysctl -p /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null
    run_cmd rm -f /etc/sysctl.d/98-reshala-enable-ipv6.conf
    log "-> IPv6 реанимирован."
    printf "%b\n" "${C_GREEN}✅ РЕАНИМАЦИЯ ЗАВЕРШЕНА.${C_RESET}"
}

ipv6_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Возвращаюсь в главное меню...${C_RESET}"; sleep 1; return' INT

    while true; do
        clear
        echo "--- УПРАВЛЕНИЕ IPv6 ---"
        printf "Статус IPv6: %b\n" "$(check_ipv6_status)"
        echo "--------------------------"
        echo "   1. Кастрировать (Отключить)"
        echo "   2. Реанимировать (Включить)"
        echo "   b. Назад в главное меню"
        
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

# ВОТ ОНА - ИСПРАВЛЕННАЯ ФУНКЦИЯ ПРОСМОТРА ЛОГОВ (БЕЗ AWK!)
view_logs_realtime() { 
    local log_path="$1"; local log_name="$2"; 
    # Если файла нет, создаем его, чтобы tail не ругался
    if [ ! -f "$log_path" ]; then 
        run_cmd touch "$log_path"
        run_cmd chmod 666 "$log_path"
    fi
    echo "[*] Смотрю журнал '$log_name'... (CTRL+C, чтобы свалить)"
    printf "%b[+] Лог-файл: %s${C_RESET}
" "${C_CYAN}" "$log_path"
    local original_int_handler=$(trap -p INT)
    trap "printf '
%b
' '${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT
    # Просто tail -f, как в старые добрые времена — без обработки!
    run_cmd tail -f -n 50 "$log_path"
    if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi
    return 0
}

view_docker_logs() { 
    local service_path="$1"
    local service_name="$2"
    
    if [ -z "$service_path" ] || [ ! -f "$service_path" ]; then 
        printf "%b\n" "❌ ${C_RED}Путь к Docker-compose не найден. Возможно, ты что-то удалил руками?${C_RESET}"
        sleep 2
        return
    fi
    
    echo "[*] Смотрю потроха '$service_name'... (CTRL+C, чтобы свалить)"
    local original_int_handler=$(trap -p INT)
    trap "printf '\n%b\n' '${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT
    
    (cd "$(dirname "$service_path")" && run_cmd docker compose logs -f) || true
    
    if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi
    return 0
}

uninstall_script() { 
    printf "%b\n" "${C_RED}Точно хочешь выгнать Решалу?${C_RESET}"
    read -p "Это снесёт скрипт, конфиги и алиасы. (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then 
        echo "Правильное решение."
        wait_for_enter
        return
    fi
    
    echo "Прощай, босс. Начинаю самоликвидацию..."
    if [ -f "$INSTALL_PATH" ]; then 
        run_cmd rm -f "$INSTALL_PATH"
        echo "✅ Главный файл снесён."
        log "-> Скрипт удалён."
    fi
    if [ -f "/root/.bashrc" ]; then 
        run_cmd sed -i "/alias reshala='sudo reshala'/d" /root/.bashrc
        echo "✅ Алиас выпилен."
        log "-> Алиас удалён."
    fi
    if [ -f "$CONFIG_FILE" ]; then 
        rm -f "$CONFIG_FILE"
        echo "✅ Конфиг стёрт."
        log "-> Конфиг удалён."
    fi
    if [ -f "$LOGFILE" ]; then 
        run_cmd rm -f "$LOGFILE"
        echo "✅ Журнал сожжён."
    fi
    printf "%b\n" "${C_GREEN}✅ Самоликвидация завершена.${C_RESET}"
    echo "   Переподключись, чтобы алиас 'reshala' сдох."
    exit 0
}

# ============================================================ #
#                    МЕНЮ ОЧИСТКИ DOCKER                       #
# ============================================================ #
docker_cleanup_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Возвращаюсь в главное меню...${C_RESET}"; sleep 1; return' INT

    while true; do
        clear
        echo "--- УПРАВЛЕНИЕ DOCKER: ОЧИСТКА ДИСКА ---"
        echo "Выбери действие для освобождения места:"
        echo "----------------------------------------"
        echo "   1. 📊 Показать самые большие образы"
        echo "   2. 🧹 Простая очистка (висячие образы, кэш)"
        echo "   3. 💥 Полная очистка неиспользуемых образов"
        echo "   4. 🗑️ Очистка неиспользуемых томов (ОСТОРОЖНО!)"
        echo "   5. 📈 Показать итоговое использование диска"
        echo "   b. Назад"
        echo "----------------------------------------"
        read -r -p "Твой выбор: " choice || continue

        case $choice in
            1)
                echo ""; echo "[*] Самые большие Docker-образы:"; echo "----------------------------------------"
                docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" | sort -rh
                wait_for_enter
                ;;
            2)
                echo ""; echo "🧹 Простая очистка (system prune)"
                echo "Удаляет: висячие образы, остановленные контейнеры, кэш сборки, сети без контейнеров."
                read -p "Выполнить? Это безопасно. (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    docker system prune -f
                    printf "\n%b\n" "${C_GREEN}✅ Простая очистка завершена.${C_RESET}"
                fi
                wait_for_enter
                ;;
            3)
                echo ""; echo "💥 Полная очистка образов (image prune -a)"
                printf "%b\n" "${C_RED}Внимание:${C_RESET} Если у тебя есть остановленные контейнеры, их образы тоже удалятся!"
                read -p "Точно продолжить? (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    docker image prune -a -f
                    printf "\n%b\n" "${C_GREEN}✅ Полная очистка образов завершена.${C_RESET}"
                fi
                wait_for_enter
                ;;
            4)
                echo ""; echo "🗑️ Очистка томов (volume prune)"
                printf "%b\n" "${C_RED}ОСТОРОЖНО!${C_RESET} Удаляет все тома, не используемые ни одним контейнером (даже остановленным)."
                printf "%b\n" "Если у тебя есть важные данные в остановленных контейнерах — НЕ ДЕЛАЙ ЭТОГО!"
                read -p "Ты уверен, что хочешь это сделать? (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    docker volume prune -f
                    printf "\n%b\n" "${C_GREEN}✅ Очистка томов завершена.${C_RESET}"
                fi
                wait_for_enter
                ;;
            5)
                echo ""; echo "[*] Итоговое использование Docker:"
                echo "----------------------------------------"
                docker system df
                wait_for_enter
                ;;
            [bB]) break ;;
            *) printf "%b\n" "${C_RED}Не та кнопка. Выбирай 1-5 или 'b'.${C_RESET}"; sleep 2 ;;
        esac
    done

    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

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
# 2. Сервер с нестандартным портом (без пароля)
# root@11.22.33.44:2222
#
# 3. Сервер с простым паролем (авто-вход)
# user@myserver.com MyPassword123
#
# 4. Пароль со спецсимволом '$' (нужно экранирование)
# user@problem.server MyPa\$\$wordWithDollar
#
# 5. Пароль с пробелами и спецсимволами (лучше в кавычках)
# user@super.server:2200 'My Crazy Password !@# %'
#
# --- ДОБАВЛЕНИЕ КЛЮЧА НА ТЕКУЩИЙ СЕРВЕР ---
#
# Чтобы добавить ключ на этот же сервер, где запущен "Решала",
# используй специальный адрес 'localhost'. Пароль не нужен.
# root@localhost
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
        log "Добавлен SSH-ключ локально."
    fi
    
    chmod 700 /root/.ssh
    chmod 600 "$auth_keys_file"
    printf "    %b\n" "${C_GRAY}(Ключ добавлен в ${auth_keys_file})${C_RESET}"
}

_ssh_add_keys() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_RED}❌ Операция отменена. Возвращаюсь...${C_RESET}"; sleep 1; return 1' INT

    clear; printf "%b\n" "${C_CYAN}--- МАССОВОЕ ДОБАВЛЕНИЕ SSH-КЛЮЧЕЙ ---${C_RESET}"; printf "%s\n" "Этот модуль поможет тебе закинуть твой SSH-ключ на все твои серверы.";
    
    printf "\n%b\n" "${C_BOLD}[ ШАГ 1: Подготовь публичный ключ ]${C_RESET}"; printf "%b\n" "Эти команды нужно выполнять на ${C_YELLOW}ТВОЁМ ЛИЧНОМ КОМПЬЮТЕРЕ${C_RESET}, а не на этом сервере."; printf "\n%b\n" "${C_CYAN}--- Для Windows ---${C_RESET}"; printf "%s\n" "1. Открой 'Командную строку' (cmd) или 'PowerShell'."; printf "%s\n" "2. Если ключ не создан, выполни команду (просто нажимай Enter на все вопросы):"; printf "   %b\n" "${C_GREEN}ssh-keygen -t ed25519${C_RESET}"; printf "%b\n" "3. Чтобы посмотреть и скопировать твой ${C_YELLOW}ПУБЛИЧНЫЙ${C_RESET} ключ, выполни:"; printf "   %b\n" "${C_GREEN}type %USERPROFILE%\\.ssh\\id_ed25519.pub${C_RESET}"; printf "%s\n" "   (Если команда выдаёт ошибку, значит ключ не найден. Вернись к пункту 2)."; printf "\n%b\n" "${C_CYAN}--- Для Linux или macOS ---${C_RESET}"; printf "%s\n" "1. Открой терминал."; printf "%b\n" "2. Если ключ не создан, выполни: ${C_GREEN}ssh-keygen -t ed25519${C_RESET}"; printf "%b\n" "3. Посмотри и скопируй твой ${C_YELLOW}ПУБЛИЧНЫЙ${C_RESET} ключ: ${C_GREEN}cat ~/.ssh/id_ed25519.pub${C_RESET}"; printf "\n%s\n" "Скопируй всю строку, которая начинается с 'ssh-ed25519...'.";
    
    while true; do
        read -p $'\nТы скопировал свой ПУБЛИЧНЫЙ ключ и готов продолжить? (y/n): ' confirm_key || return 1
        case "$confirm_key" in
            [yY]) break ;;
            [nN]) printf "\n%b\n" "${C_RED}Отмена. Возвращаю в меню.${C_RESET}"; sleep 2; return ;;
            *) printf "\n%b\n" "${C_RED}Хуйню не вводи. Напиши 'y' (да) или 'n' (нет).${C_RESET}" ;;
        esac
    done
    
    clear; printf "%b\n" "${C_BOLD}[ ШАГ 2: Вставь свой ключ ]${C_RESET}"; read -p "Вставь сюда свой публичный ключ (ssh-ed25519...): " PUBKEY || return 1; if ! [[ "$PUBKEY" =~ ^ssh-(rsa|dss|ed25519|ecdsa) ]]; then printf "\n%b\n" "${C_RED}❌ Это не похоже на SSH-ключ. Давай по новой.${C_RESET}"; return; fi;
    
    local SERVERS_FILE_PATH; SERVERS_FILE_PATH="$(pwd)/servers.txt"
    clear; printf "%b\n" "${C_BOLD}[ ШАГ 3: Управление списком серверов ]${C_RESET}"
    if [ -f "$SERVERS_FILE_PATH" ]; then
        printf "%b\n" "Найден существующий файл со списком серверов: ${C_YELLOW}${SERVERS_FILE_PATH}${C_RESET}"
        read -p "Что делаем? (1-Редактировать, 2-Использовать как есть, 3-Удалить и создать заново): " choice || return 1
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

    clear; printf "%b\n" "${C_BOLD}[ ШАГ 4: Установка ключа на серверы ]${C_RESET}"; printf "%s\n" "Сейчас я буду по очереди подключаться к каждому серверу."; _ensure_package_installed "sshpass" || return; wait_for_enter;
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

        printf "\n%b\n" "${C_CYAN}--> Добавляю ключ на $host_port_part...${C_RESET}"
        
        local port_arg=""; if [ -n "$port" ]; then port_arg="-p $port"; fi
        
        if [ -n "$password" ]; then
            printf "%b\n" "${C_GRAY}    (использую пароль из файла)${C_RESET}"
            if ! sshpass -p "$password" ssh-copy-id -i "$TEMP_KEY_BASE" $port_arg -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host"; then
                printf "    %b\n" "${C_RED}❌ Ошибка. Автоматический вход не удался. Проверь пароль в файле.${C_RESET}"
                log "Ошибка добавления ключа на $host (sshpass)."
            else
                printf "    %b\n" "${C_GREEN}✅ Успех!${C_RESET}"
                printf "    %b\n" "${C_GRAY}(Ключ добавлен в ${host}:~/.ssh/authorized_keys)${C_RESET}"
                log "Добавлен SSH-ключ на $host."
            fi
        else
            printf "%b\n" "${C_GRAY}    (пароль не указан, будет запрошен вручную)${C_RESET}"
            if ! ssh-copy-id -i "$TEMP_KEY_BASE" $port_arg -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host"; then
                printf "    %b\n" "${C_RED}❌ Ошибка. Проверь введённый пароль или доступность хоста.${C_RESET}"
                log "Ошибка добавления ключа на $host (manual)."
            else
                printf "    %b\n" "${C_GREEN}✅ Успех!${C_RESET}"
                printf "    %b\n" "${C_GRAY}(Ключ добавлен в ${host}:~/.ssh/authorized_keys)${C_RESET}"
                log "Добавлен SSH-ключ на $host."
            fi
        fi
    done < <(grep -v -E '^\s*#|^\s*$' "$SERVERS_FILE_PATH")
    rm -f "$TEMP_KEY_BASE" "$TEMP_KEY_FILE"
    
    printf "\n%b\n" "${C_GREEN}🎉 Готово! Процесс завершён.${C_RESET}"
    read -p "Хочешь удалить файл со списком серверов '${SERVERS_FILE_PATH}'? (y/n): " cleanup_choice
    if [[ "$cleanup_choice" == "y" || "$cleanup_choice" == "Y" ]]; then rm -f "$SERVERS_FILE_PATH"; printf "%b\n" "${C_GREEN}✅ Файл удалён.${C_RESET}"; fi

    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

security_menu() {
    local original_trap; original_trap=$(trap -p INT)
    trap 'printf "\n%b\n" "${C_YELLOW}🔙 Возвращаюсь в главное меню...${C_RESET}"; sleep 1; return' INT

    while true; do
        clear; echo "--- МЕНЮ БЕЗОПАСНОСТИ ---"; echo "Здесь собраны инструменты для укрепления твоего сервера."; echo "----------------------------------"; echo "   [1] Добавить SSH-ключи на серверы 🔑"; echo "   [b] Назад в главное меню"; echo "----------------------------------"; 
        read -r -p "Твой выбор: " choice || continue
        case $choice in
            1) _ssh_add_keys; wait_for_enter;;
            [bB]) break;;
            *) printf "%b\n" "${C_RED}Не та кнопка, босс. Попробуй ещё раз.${C_RESET}"; sleep 2;;
        esac
    done

    if [ -n "$original_trap" ]; then eval "$original_trap"; else trap - INT; fi
}

# ============================================================ #
#          ОБНОВЛЕНИЕ СИСТЕМЫ + EOL FIX (ULTRA EDITION)        #
# ============================================================ #
offer_initial_update() {
    # Проверяем, предлагали ли мы уже сегодня обновление
    local last_check; last_check=$(load_path "LAST_SYS_UPDATE")
    local today; today=$(date +%Y%m%d)
    
    if [ "$last_check" == "$today" ]; then
        # Уже спрашивали сегодня, пропускаем
        return
    fi
    
    clear
    printf "%b\n" "${C_CYAN}👋 Здарова, босс. Новый день — новые заботы.${C_RESET}"
    echo "Система давно не проверялась на наличие обновлений."
    echo "Актуальный софт — залог того, что тебя не взломают."
    echo ""
    read -p "Запустить быструю проверку и обновление системы? (y/n): " confirm_initial
    
    if [[ "$confirm_initial" == "y" || "$confirm_initial" == "Y" ]]; then
        # Запускаем нашу мощную функцию
        fix_eol_and_update
    else
        echo "Ок, напомню завтра. Не запускай систему."
        # Запоминаем дату отказа, чтобы сегодня больше не долбить
        save_path "LAST_SYS_UPDATE" "$today"
        sleep 1
    fi
}

fix_eol_and_update() {
    # Проверяем, есть ли apt (Debian/Ubuntu)
    if ! command -v apt &> /dev/null; then 
        echo "⚠️  Утилита apt не найдена. Похоже, это не Debian/Ubuntu. Я тут бессилен."
        wait_for_enter
        return
    fi

    clear
    printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    printf "%b\n" "${C_CYAN}║           ЦЕНТР ОБНОВЛЕНИЯ И РЕАНИМАЦИИ СИСТЕМЫ              ║${C_RESET}"
    printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo "📝 ЧТО МЫ СЕЙЧАС БУДЕМ ДЕЛАТЬ:"
    echo "1. Проверим интернет (без него каши не сваришь)."
    echo "2. Попробуем обновить список пакетов через официальные зеркала."
    echo "3. Если получим ошибку '404 Not Found', значит твоя версия Ubuntu устарела (EOL)."
    echo "   В этом случае я предложу переключиться на архивные сервера (Old Releases),"
    echo "   чтобы ты снова мог ставить программы и обновления безопасности."
    echo "---------------------------------------------------------------------"
    echo ""
    
    # 1. Проверка интернета перед боем
    printf "%b" "[*] Проверяю связь с внешним миром... "
    if curl -s --connect-timeout 3 google.com >/dev/null; then
        printf "%b\n" "${C_GREEN}Есть контакт.${C_RESET}"
    else
        printf "%b\n" "${C_RED}Связи нет!${C_RESET}"
        echo "   Проверь DNS или кабель. Я не волшебник, без инета не обновлю."
        wait_for_enter
        return
    fi

    printf "%b\n" "${C_BOLD}[*] Попытка стандартного обновления (apt update)...${C_RESET}"
    
    # 2. Пробуем обновиться по-человечески
    if run_cmd apt-get update; then
        # Если update прошёл успешно - просто обновляем
        printf "\n%b\n" "${C_GREEN}✅ Отлично! Официальные зеркала доступны.${C_RESET}"
        echo "Запускаю полное обновление пакетов..."
        run_cmd apt-get upgrade -y
        run_cmd apt-get full-upgrade -y
        run_cmd apt-get autoremove -y
        run_cmd apt-get autoclean
        
        # Проверка на наличие sudo (бывает слетает в минималках)
        if ! command -v sudo &> /dev/null; then
             echo "   -> Доустанавливаю sudo, а то его нет..."
             run_cmd apt-get install -y sudo
        fi
        
        # Запоминаем дату, чтобы сегодня больше не приставать
        save_path "LAST_SYS_UPDATE" "$(date +%Y%m%d)"
        
        printf "\n%b\n" "${C_GREEN}✅ Система полностью обновлена. Всё работает штатно.${C_RESET}"
        log "Обновление системы (Standard) успешно."
        wait_for_enter
    else
        # 3. Если упало - объясняем юзеру, что случилось
        printf "\n%b\n" "${C_RED}❌ ОШИБКА ОБНОВЛЕНИЯ! (Зеркала ответили 404 Not Found)${C_RESET}"
        echo "---------------------------------------------------------------------"
        printf "%b\n" "${C_YELLOW}ЧТО ЭТО ЗНАЧИТ:${C_RESET}"
        echo "Твоя версия Ubuntu/Debian устарела и официально больше не поддерживается (EOL)."
        echo "Разработчики удалили файлы с основных серверов, поэтому 'apt update' не работает."
        echo ""
        echo "КАК ЭТО ЛЕЧИТЬ:"
        echo "Нужно заменить адреса в конфигах с 'archive.ubuntu.com' на 'old-releases.ubuntu.com'."
        echo "Это вернёт возможность устанавливать софт."
        echo "---------------------------------------------------------------------"
        
        read -p "🚑 Применить лечение (FIX EOL) и обновить систему? (y/n): " confirm_fix
        
        if [[ "$confirm_fix" == "y" || "$confirm_fix" == "Y" ]]; then
            log "Запуск процедуры EOL Fix..."
            
            # --- БЭКАП ---
            local BACKUP_DIR="/var/backups/reshala/apt_sources"
            local TIMESTAMP
            TIMESTAMP=$(date +%Y%m%d_%H%M%S)
            
            printf "\n%b\n" "${C_YELLOW}📦 Сначала делаю бэкап старых конфигов в ${BACKUP_DIR}...${C_RESET}"
            run_cmd mkdir -p "$BACKUP_DIR"
            
            if [ -f /etc/apt/sources.list ]; then
                run_cmd cp /etc/apt/sources.list "$BACKUP_DIR/sources.list.$TIMESTAMP"
                echo "   -> sources.list сохранён."
            fi
            
            if [ -d /etc/apt/sources.list.d ] && [ "$(ls -A /etc/apt/sources.list.d 2>/dev/null)" ]; then
                run_cmd cp -r /etc/apt/sources.list.d "$BACKUP_DIR/sources.list.d.$TIMESTAMP"
                echo "   -> sources.list.d/ сохранён."
            fi

            # --- ЛЕЧЕНИЕ ---
            printf "\n%b\n" "${C_YELLOW}🔧 Исправляю адреса серверов (sed surgery)...${C_RESET}"
            
            # Лечим основной sources.list
            run_cmd sed -i -r 's/([a-z]{2}\.)?archive.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
            run_cmd sed -i -r 's/security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
            # Порты для ARM/RPi
            run_cmd sed -i -r 's/ports.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list

            # Пробуем лечить и файлы в .d
            if [ -d /etc/apt/sources.list.d ]; then
                find /etc/apt/sources.list.d -name "*.list" -type f -exec sudo sed -i -r 's/([a-z]{2}\.)?archive.ubuntu.com/old-releases.ubuntu.com/g' {} +
                find /etc/apt/sources.list.d -name "*.list" -type f -exec sudo sed -i -r 's/security.ubuntu.com/old-releases.ubuntu.com/g' {} +
            fi
            
            printf "%b\n" "${C_GREEN}✅ Адреса заменены. Пробую обновиться снова...${C_RESET}"
            
            if run_cmd apt-get update; then
                printf "\n%b\n" "${C_GREEN}✨ ПОЛУЧИЛОСЬ! Система увидела репозитории!${C_RESET}"
                echo "Запускаю установку обновлений..."
                run_cmd apt-get upgrade -y
                run_cmd apt-get full-upgrade -y
                run_cmd apt-get autoremove -y
                run_cmd apt-get autoclean
                
                # Запоминаем дату
                save_path "LAST_SYS_UPDATE" "$(date +%Y%m%d)"
                
                printf "\n%b\n" "${C_GREEN}✅ EOL Fix сработал, всё обновлено. Живём!${C_RESET}"
                log "Обновление системы (EOL fix) успешно завершено."
            else
                printf "\n%b\n" "${C_RED}❌ Не прокатило. Пациент скорее мёртв.${C_RESET}"
                echo "Возможные причины:"
                echo "1. Проблемы с DNS/Фаерволом."
                echo "2. У тебя архитектура или версия, которой нет даже в архиве."
                echo "Бэкап лежит тут: $BACKUP_DIR"
                log "Обновление после EOL fix не удалось."
            fi
        else
            echo "Хозяин - барин. Но без обновлений далеко не уедешь."
            # Если отказался, всё равно запоминаем дату, чтобы не спрашивать 100 раз в день
            save_path "LAST_SYS_UPDATE" "$(date +%Y%m%d)"
        fi
        wait_for_enter
    fi
}

# ============================================================ #
#                   ГЛАВНОЕ МЕНЮ И ИНФО-ПАНЕЛЬ                 #
# ============================================================ #
display_header() {
    # Собираем данные
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}')
    local location; location=$(get_location)
    local os_ver; os_ver=$(get_os_ver)
    local kernel; kernel=$(get_kernel)
    local uptime; uptime=$(get_uptime)
    local virt; virt=$(get_virt_type)
    local ping; ping=$(get_ping_google)
    
    local cpu_info; cpu_info=$(get_cpu_info_clean)
    local cpu_load_viz; cpu_load_viz=$(get_cpu_load_visual)
    local ram_viz; ram_viz=$(get_ram_visual)
    
    # Разбираем диск
    local disk_raw; disk_raw=$(get_disk_visual)
    local disk_type; disk_type=$(echo "$disk_raw" | cut -d'|' -f1)
    local disk_viz; disk_viz=$(echo "$disk_raw" | cut -d'|' -f2)
    
    local hoster_info; hoster_info=$(get_hoster_info)
    local users_online; users_online=$(get_active_users)
    
    # СКОРОСТЬ ПОРТА
    local port_speed; port_speed=$(get_port_speed)
    
    # Сеть
    local net_status; net_status=$(get_net_status)
    local cc; cc=$(echo "$net_status" | cut -d'|' -f1)
    local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2)
    local cc_status
    if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then 
        if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}MAX (bbr+cake)${C_RESET}"; 
        else cc_status="${C_GREEN}ON (bbr+$qdisc)${C_RESET}"; fi
    else cc_status="${C_YELLOW}STOCK ($cc)${C_RESET}"; fi
    
    local ipv6_status; ipv6_status=$(check_ipv6_status)

    clear
    # Ширина левой колонки УВЕЛИЧЕНА до 18 для идеального выравнивания
    local w=18

    printf "%b\n" "${C_CYAN}╔═[ ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ]═════════════════════════════╗${C_RESET}"
    printf "%b\n" "${C_CYAN}║${C_RESET}"
    
    # --- БЛОК 1: СИСТЕМА ---
    printf "%b\n" "${C_CYAN}╠═[ СИСТЕМА ]${C_RESET}"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "ОС / Ядро" "$os_ver ($kernel)"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_WHITE}%s${C_RESET}  (Юзеров: $users_online)\n" "Аптайм" "$uptime"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Виртуалка" "$virt"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_YELLOW}%s${C_RESET}  (Пинг: $ping) [${C_CYAN}$location${C_RESET}]\n" "IP Адрес" "$ip_addr"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Хостер" "$hoster_info"
    
    printf "%b\n" "${C_CYAN}║${C_RESET}"
    
    # --- БЛОК 2: РЕСУРСЫ ---
    printf "%b\n" "${C_CYAN}╠═[ ЖЕЛЕЗО ]${C_RESET}"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "CPU Модель" "$cpu_info"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : %s\n" "Загрузка CPU" "$cpu_load_viz"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : %s\n" "Память (RAM)" "$ram_viz"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : %s\n" "Диск ($disk_type)" "$disk_viz"

    printf "%b\n" "${C_CYAN}║${C_RESET}"
    
    # --- БЛОК 3: STATUS ---
    printf "%b\n" "${C_CYAN}╠═[ STATUS ]${C_RESET}"
    
    if [[ "$SERVER_TYPE" == "Панель и Нода" ]]; then
        printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_GREEN}%s${C_RESET}\n" "Remnawave" "🔥 COMBO (Панель + Нода)"
        printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Версии" "P: v${PANEL_VERSION} | N: v${NODE_VERSION}"
    elif [[ "$SERVER_TYPE" == "Панель" ]]; then
        printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_GREEN}%s${C_RESET} (v${PANEL_VERSION})\n" "Remnawave" "Панель управления"
    elif [[ "$SERVER_TYPE" == "Нода" ]]; then
        printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_GREEN}%s${C_RESET} (v${NODE_VERSION})\n" "Remnawave" "Боевая Нода"
    elif [[ "$SERVER_TYPE" == "Сервак не целка" ]]; then
         printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_RED}%s${C_RESET}\n" "Remnawave" "НЕ НАЙДЕНО / СТОРОННИЙ СОФТ"
    else
        printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Remnawave" "Не установлена"
    fi

    if [ "$BOT_DETECTED" -eq 1 ]; then 
        printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_CYAN}АКТИВЕН${C_RESET} (v${BOT_VERSION})\n" "Bedalaga" 
    fi
    
    if [[ "$WEB_SERVER" != "Не определён" ]]; then 
        printf "║ ${C_GRAY}%-${w}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Web-Server" "$WEB_SERVER" 
    fi
    
    # Разделитель для сетевых настроек
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : %b\n" "Канал (Link)" "${C_BOLD}${port_speed}${C_RESET}"
    printf "║ ${C_GRAY}%-${w}s${C_RESET} : %b  |  IPv6: %b\n" "Тюнинг" "$cc_status" "$ipv6_status"
    
    printf "%b\n" "${C_CYAN}╚════════════════════════════════════════════════════════════════╝${C_RESET}"
}

show_menu() {
    # === ЗАЩИТА ОТ CTRL+C (ANTI-SPAM EDITION) ===
    trap 'printf "\r\033[K%b" "${C_RED}🛑 Куда собрался? Жми [q], чтобы выйти как нормальный пацан!${C_RESET}"; sleep 0.8' SIGINT

    while true; do
        scan_server_state
        check_for_updates
        display_header

        # === БАННЕР ОБНОВЛЕНИЯ ===
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
            printf "\n%b‼️ ДОСТУПНО ОБНОВЛЕНИЕ ДЛЯ «РЕШАЛЫ»! УСТАНОВИ НОВУЮ ВЕРСИЮ — СТАРЬЁ РЖАВЕЕТ! ‼️%b\n\n" "${C_BOLD}${C_RED}" "${C_RESET}"
        fi

        printf "\n%s\n\n" "Чё делать будем, босс?";
        printf "   [0] %b\n" "🔄 ОБНОВИТЬ СИСТЕМУ (Умное обновление + Лечение EOL)"
        echo "   [1] 🚀 Управление «Форсажем» (BBR+CAKE)"
        echo "   [2] 🌐 Управление IPv6"
        echo "   [3] 📜 Посмотреть журнал «Решалы»"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo "   [4] 🤖 Посмотреть логи Бота"; fi
        
        if [[ "$SERVER_TYPE" == "Панель и Нода" ]]; then
             echo "   [5] 📊 Посмотреть логи Панели (Основное)"
        elif [[ "$SERVER_TYPE" == "Панель" ]]; then
             echo "   [5] 📊 Посмотреть логи Панели"
        elif [[ "$SERVER_TYPE" == "Нода" ]]; then
             echo "   [5] 📊 Посмотреть логи Ноды"
        fi

        printf "   [6] %b\n" "🛡️ Безопасность сервера ${C_YELLOW}(SSH ключи)${C_RESET}"
        echo "   [7] 🐳 Управление Docker"
        echo "   [8] 💿 Установить Панель Remnawave (High-Load)"
        printf "   [9] %b\n" "⚡ Тест скорости до Москвы (Speedtest)"

        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
            printf "   %b[u] ‼️ОБНОВИТЬ РЕШАЛУ‼️%b\n" "${C_BOLD}${C_YELLOW}" "${C_RESET}"
        elif [[ "$UPDATE_CHECK_STATUS" != "OK" ]]; then
            printf "\n%b\n" "${C_RED}⚠️ Ошибка проверки обновлений (см. лог)${C_RESET}"
        fi

        echo ""
        printf "   [d] %b\n" "${C_RED}🗑️ Снести Решалу нахуй (Удаление)${C_RESET}"
        echo "   [q] 🚪 Свалить (Выход)"
        echo "------------------------------------------------------"

        local choice=""
        
        if ! read -r -p "Твой выбор, босс: " choice; then
            continue
        fi

        log "Пользователь выбрал пункт меню: $choice"

        case $choice in
            0) fix_eol_and_update;;
            1) apply_bbr; wait_for_enter;;
            2) ipv6_menu;;
            3) view_logs_realtime "$LOGFILE" "Решалы";;
            4) if [ "$BOT_DETECTED" -eq 1 ]; then view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота"; else echo "Нет такой кнопки."; sleep 2; fi;;
            5) if [[ "$SERVER_TYPE" != "Чистый сервак" && "$SERVER_TYPE" != "Сервак не целка" ]]; then view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE"; else echo "Нет такой кнопки."; sleep 2; fi;;
            6) security_menu;;
            7) docker_cleanup_menu;;
            8) run_module "install_panel.sh";;
            9) run_speedtest_moscow;;
            [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой?"; sleep 2; fi;;
            [dD]) uninstall_script;;
            [qQ]) 
                trap - SIGINT
                echo "Был рад помочь. Не обосрись. 🥃"
                break
                ;;
            *) echo "Ты прикалываешься?"; sleep 2;;
        esac
    done
}

# ============================================================ #
#                       ТОЧКА ВХОДА В СКРИПТ                   #
# ============================================================ #
main() {
    # Создаем лог при старте, чтобы он точно был
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