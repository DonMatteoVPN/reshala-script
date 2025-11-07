#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v0.61 dev - REFACTORED         == #
# ============================================================ #
# ==  Рефакторинг: убраны дубли, улучшена читаемость, добавлен
# ==  детект/попытка установки BBR2/BBR3 (модуль/модули пытаются
# ==  загрузиться через modprobe; если это невозможно — даётся
# ==  понятное сообщение и инструкции).                        == #
# ============================================================ #

set -euo pipefail

readonly VERSION="v0.61 dev (refactor)"
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/dev/install_reshala.sh"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala_ops.log"
INSTALL_PATH="/usr/local/bin/reshala"

# Цвета
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_GRAY='\033[0;90m';

# Общие
SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён"
UPDATE_AVAILABLE=0; LATEST_VERSION=""; UPDATE_CHECK_STATUS="OK"

# ----------------- УТИЛИТЫ -----------------
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | sudo tee -a "$LOGFILE" >/dev/null; }
wait_for_enter(){ read -p $'\nНажми Enter, чтобы продолжить...'; }
save_path(){ local key="$1"; local value="$2"; touch "$CONFIG_FILE"; sed -i "/^$key=/d" "$CONFIG_FILE" || true; echo "$key=\"$value\"" >> "$CONFIG_FILE"; }
load_path(){ local key="$1"; [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" &>/dev/null || true; eval echo "\${$key:-}"; }

# Собираем сетевой статус в простом виде: CC|QDISC
get_net_status(){
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")
    local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a")
    if [ -z "$qdisc" ] || [ "$qdisc" = "pfifo_fast" ]; then
        qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n 1) || qdisc="n/a"
    fi
    echo "$cc|$qdisc"
}

# ----------------- ОБНОВЛЕНИЯ -----------------
check_for_updates(){
    UPDATE_AVAILABLE=0; LATEST_VERSION=""; UPDATE_CHECK_STATUS="OK"
    local max_attempts=3; local attempt=1
    local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
    log "Начинаю проверку обновлений: $url_with_buster"

    while [ $attempt -le $max_attempts ]; do
        local body; body=$(curl -4 -fsS --connect-timeout 7 --max-time 15 "$url_with_buster" 2>>"$LOGFILE" || true)
        if [ -n "$body" ]; then
            LATEST_VERSION=$(echo "$body" | grep -m1 "readonly VERSION" | sed -E 's/.*VERSION=\"?([^\" ]+).*/\1/') || true
            if [ -n "$LATEST_VERSION" ]; then
                log "Удалённая версия: $LATEST_VERSION. Локальная: $VERSION."
                local local_ver_num remote_ver_num
                local_ver_num=$(echo "$VERSION" | sed 's/[^0-9.]*//g' || true)
                remote_ver_num=$(echo "$LATEST_VERSION" | sed 's/[^0-9.]*//g' || true)
                if [ -n "$local_ver_num" ] && [ -n "$remote_ver_num" ] && [ "$local_ver_num" != "$remote_ver_num" ]; then
                    local highest_ver_num
                    highest_ver_num=$(printf '%s\n%s' "$local_ver_num" "$remote_ver_num" | sort -V | tail -n1)
                    if [[ "$highest_ver_num" == "$remote_ver_num" ]]; then UPDATE_AVAILABLE=1; fi
                fi
                return 0
            fi
        fi
        log "Попытка $attempt: не удалось получить корректный ответ."
        sleep 2
        attempt=$((attempt+1))
    done

    UPDATE_CHECK_STATUS="ERROR"
    log "Ошибка проверки обновлений после $max_attempts попыток."
    return 1
}

run_update(){
    read -p "Доступна версия $LATEST_VERSION. Обновляемся? (y/n): " confirm_update
    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then echo -e "${C_YELLOW}Отмена.${C_RESET}"; wait_for_enter; return; fi
    log "Запрошено обновление до $LATEST_VERSION"
    local tmp; tmp=$(mktemp)
    if ! wget -4 -q -O "$tmp" "${SCRIPT_URL}?cache_buster=$(date +%s)"; then echo -e "${C_RED}Не удалось скачать обновление.${C_RESET}"; rm -f "$tmp"; wait_for_enter; return; fi
    local dv; dv=$(grep -m1 "readonly VERSION" "$tmp" | sed -E 's/.*VERSION=\"?([^\" ]+).*/\1/' || true)
    if [ -z "$dv" ] || [ "$dv" != "$LATEST_VERSION" ]; then echo -e "${C_RED}Провал валидации скачанного скрипта.${C_RESET}"; rm -f "$tmp"; wait_for_enter; return; fi
    sudo cp -- "$tmp" "$INSTALL_PATH" && sudo chmod +x "$INSTALL_PATH"; rm -f "$tmp"
    echo -e "${C_GREEN}Обновлено до $LATEST_VERSION.${C_RESET}"
    sleep 1; exec "$INSTALL_PATH"
}

# ----------------- ДЕТЕКТ (DOCKER, WEB, BOT) -----------------
get_docker_version(){ local container_name="$1"; local version="";
    version=$(sudo docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$container_name" 2>/dev/null || true)
    [ -n "$version" ] && echo "$version" && return
    version=$(sudo docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null | grep -E '^(APP_VERSION|VERSION)=' | head -n1 | cut -d'=' -f2 || true)
    [ -n "$version" ] && echo "$version" && return
    if sudo docker exec "$container_name" test -f /app/package.json 2>/dev/null; then
        version=$(sudo docker exec "$container_name" cat /app/package.json 2>/dev/null | jq -r .version 2>/dev/null || true)
        [ -n "$version" ] && echo "$version" && return
    fi
    if sudo docker exec "$container_name" test -f /app/VERSION 2>/dev/null; then
        version=$(sudo docker exec "$container_name" cat /app/VERSION 2>/dev/null | tr -d '\n\r' || true)
        [ -n "$version" ] && echo "$version" && return
    fi
    local image_tag; image_tag=$(sudo docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null | cut -d':' -f2 || true)
    if [ -n "$image_tag" ] && [ "$image_tag" != "latest" ]; then echo "$image_tag"; return; fi
    local image_id; image_id=$(sudo docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null || true)
    echo "latest (образ: ${image_id:0:7})"
}

scan_server_state(){
    SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён"
    local docker_names
    docker_names=$(sudo docker ps --format '{{.Names}}' 2>/dev/null || true)
    if echo "$docker_names" | grep -q "^remnawave$"; then SERVER_TYPE="Панель"; PANEL_NODE_VERSION=$(get_docker_version remnawave); PANEL_NODE_PATH=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' remnawave 2>/dev/null || true); fi
    if echo "$docker_names" | grep -q "^remnanode$"; then SERVER_TYPE="Нода"; PANEL_NODE_VERSION=$(get_docker_version remnanode); PANEL_NODE_PATH=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' remnanode 2>/dev/null || true; fi
    if echo "$docker_names" | grep -q "remnawave_bot"; then BOT_DETECTED=1; BOT_VERSION=$(get_docker_version remnawave_bot); BOT_PATH=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' remnawave_bot 2>/dev/null || true); fi

    if echo "$docker_names" | grep -q "remnawave-nginx"; then local nginx_version; nginx_version=$(sudo docker exec remnawave-nginx nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"); WEB_SERVER="Nginx $nginx_version (в Docker)"
    elif echo "$docker_names" | grep -q "caddy"; then local caddy_version; caddy_version=$(sudo docker exec caddy caddy version 2>/dev/null | cut -d' ' -f1 || echo "unknown"); WEB_SERVER="Caddy $caddy_version (в Docker)"
    elif ss -tlpn | grep -q -E 'nginx|caddy|apache2|httpd'; then
        if command -v nginx &>/dev/null; then local nginx_version; nginx_version=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"); WEB_SERVER="Nginx $nginx_version (на хосте)"; fi
    fi
}

# ----------------- HARDWARE INFO -----------------
get_cpu_info(){ lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+|\s+@.*$/,"",$2); print $2; exit}'; }
get_cpu_load(){ local cores=$(nproc); local load=$(uptime | awk -F'load average: ' '{print $2}' | cut -d, -f1); echo "$load / $cores ядер"; }
get_ram_info(){ free -m | awk '/Mem:/ {printf "%.1f/%.1f GB", $3/1024, $2/1024}'; }
get_disk_info(){ local usage; usage=$(df -h / | awk 'NR==2 {print $3 "/" $2}'); local root_device; root_device=$(df / | awk 'NR==2 {print $1}'); local main_disk; main_disk=$(lsblk -no pkname "$root_device" 2>/dev/null || basename "$root_device" | sed 's/[0-9]*$//'); local disk_type="HDD"; if [ -f "/sys/block/$main_disk/queue/rotational" ]; then [ "$(cat "/sys/block/$main_disk/queue/rotational")" -eq 0 ] && disk_type="SSD"; elif [[ "$main_disk" == *"nvme"* ]]; then disk_type="SSD"; fi; echo "$disk_type ($usage)"; }
get_hoster_info(){ curl -s --connect-timeout 5 ipinfo.io/org || echo "Не определён"; }

# ----------------- BBR / MODULES -----------------
# Функция: проверяет, какие congestion control доступны, пробует modprobe для кандидатов
list_available_cc(){
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")"
}

# Попробовать загрузить модуль по списку возможных имён
try_modprobe_candidates(){
    local candidates=("tcp_bbr2" "tcp_bbr3" "bbr2" "bbr3" "tcp_bbr")
    for m in "${candidates[@]}"; do
        if modprobe -n -v "$m" &>/dev/null; then
            # модуль есть в системе и можно попытаться загрузить
            if sudo modprobe "$m" 2>/dev/null; then
                log "Успешно загружен модуль: $m"
                echo "$m"; return 0
            fi
        fi
    done
    return 1
}

# Основная логика установки/включения BBR/BBr2/BBR3: пытаемся подобрать лучший доступный
ensure_best_cc(){
    local available; available=$(list_available_cc)
    log "Доступные CC: $available"
    # желаемый порядок предпочтения
    local want=("bbr3" "bbr2" "bbr")

    # Если в available уже есть более новая, применим её
    for c in "${want[@]}"; do
        if echo "$available" | grep -qw "$c"; then
            echo "Detected preferred CC: $c"; return 0
        fi
    done

    # Попробовать загрузить модули для bbr2/bbr3
    echo "Пытаюсь подрулить дополнительные модули (bbr2/bbr3)..."
    if try_modprobe_candidates; then
        sleep 1
        available=$(list_available_cc)
        if echo "$available" | grep -q "bbr2"; then preferred="bbr2"; elif echo "$available" | grep -q "bbr3"; then preferred="bbr3"; elif echo "$available" | grep -q "bbr"; then preferred="bbr"; else preferred="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'n/a')"; fi
        echo "Найдено после попытки: $available -> выбрано: $preferred"
        # Применяем через sysctl конфиг в apply_bbr
        echo "$preferred"
        return 0
    fi

    echo "Не удалось автоматически добавить bbr2/bbr3: модуль отсутствует в этой сборке ядра."
    echo "Рекомендация: установить ядро с поддержкой BBR2/BBR3 или использовать backport-модуль. Обычно это требует установки другого образа ядра и перезагрузки."
    return 1
}

apply_bbr(){
    log "Запуск apply_bbr"
    local net_status; net_status=$(get_net_status)
    local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1)
    local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2)

    echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"

    # Если уже максимально — выйдем
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2" || "$current_cc" == "bbr3") && "$current_qdisc" == "cake" ]]; then
        echo -e "${C_GREEN}✅ Уже стоит BBR (или новее) + CAKE.${C_RESET}"; log "BBR+CAKE уже активны"; return
    fi

    # Проверим доступные контроллеры и попробуем добавить лучшее
    local available_cc; available_cc=$(list_available_cc)
    local preferred_cc="bbr"

    # если bbr2/3 есть в списке, выбрать её
    if echo "$available_cc" | grep -qw "bbr3"; then preferred_cc="bbr3"; elif echo "$available_cc" | grep -qw "bbr2"; then preferred_cc="bbr2"; fi

    # если нет — попытаемся загрузить модули
    if ! echo "$available_cc" | grep -Eqw 'bbr|bbr2|bbr3'; then
        echo "Не найден bbr/bbr2/bbr3 в доступных. Попробуем загрузить модули..."
        if try_modprobe_candidates; then
            available_cc=$(list_available_cc)
            if echo "$available_cc" | grep -qw "bbr3"; then preferred_cc="bbr3"; elif echo "$available_cc" | grep -qw "bbr2"; then preferred_cc="bbr2"; fi
        else
            echo -e "${C_YELLOW}⚠️ Модули BBR2/BBR3 недоступны в этом ядре. Нужна установка другого ядра или backport-модулей.${C_RESET}"
            log "Модули BBR2/BBR3 отсутствуют и modprobe ничего не дал"
        fi
    fi

    # CAKE?
    local cake_available=false
    if modprobe -n -v sch_cake &>/dev/null || lsmod | grep -q sch_cake; then cake_available=true; fi
    if [ "$cake_available" = false ]; then modprobe sch_fq &>/dev/null || true; fi
    local preferred_qdisc="fq"
    if [ "$cake_available" = true ]; then preferred_qdisc="cake"; fi

    # Собираем sysctl конфиг
    local tcp_fastopen_val=0; [[ $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0) -ge 1 ]] && tcp_fastopen_val=3
    local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"

    log "Устанавливаю CC=$preferred_cc QDISC=$preferred_qdisc"
    sudo rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf || true
    sudo sed -i.bak -E 's/^[[:space:]]*(net.core.default_qdisc|net.ipv4.tcp_congestion_control)/#&/' /etc/sysctl.conf || true

    cat <<EOF | sudo tee "$CONFIG_SYSCTL" > /dev/null
# === РЕШАЛА: FORSAGE CONFIG ===
net.ipv4.tcp_congestion_control = $preferred_cc
net.core.default_qdisc = $preferred_qdisc
net.ipv4.tcp_fastopen = $tcp_fastopen_val
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF

    sudo sysctl -p "$CONFIG_SYSCTL" >/dev/null || true
    echo "Новый алгоритм: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'n/a')"
    echo "Новый планировщик: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'n/a')"
    log "apply_bbr завершён"
    echo -e "${C_GREEN}✅ Готово. (CC: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'n/a'), QDisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'n/a'))${C_RESET}"
}

# ----------------- IPv6 (unchanged, но очищено) -----------------
check_ipv6_status(){
    if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"; return; fi
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo -e "${C_RED}КАСТРИРОВАН${C_RESET}"; else echo -e "${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi
}

disable_ipv6(){
    if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "${C_YELLOW}IPv6 уже недоступен (вырезан).${C_RESET}"; return; fi
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo "IPv6 уже отключён."; return; fi
    sudo tee /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null <<EOL
# === ОТКЛЮЧЕНИЕ IPv6 ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOL
    sudo sysctl -p /etc/sysctl.d/98-reshala-disable-ipv6.conf >/dev/null || true
    log "IPv6 отключён"
    echo -e "${C_GREEN}✅ IPv6 отключён.${C_RESET}"
}

enable_ipv6(){
    if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "${C_YELLOW}Невозможно — провайдер вырезал поддержку.${C_RESET}"; return; fi
    sudo rm -f /etc/sysctl.d/98-reshala-disable-ipv6.conf || true
    sudo tee /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null <<EOL
# === ВКЛЮЧЕНИЕ IPv6 ===
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOL
    sudo sysctl -p /etc/sysctl.d/98-reshala-enable-ipv6.conf >/dev/null || true
    sudo rm -f /etc/sysctl.d/98-reshala-enable-ipv6.conf || true
    log "IPv6 включён"
    echo -e "${C_GREEN}✅ IPv6 включён.${C_RESET}"
}

# ----------------- ЛОГИ / DOCKER LOGS -----------------
view_logs_realtime(){ local log_path="$1"; local log_name="$2"; if [ ! -f "$log_path" ]; then echo -e "${C_RED}Лог пуст.${C_RESET}"; sleep 2; return; fi; echo "[*] Просмотр $log_name (CTRL+C чтобы выйти)"; trap "echo; echo -e '${C_GREEN}Возвращаюсь...${C_RESET}'; sleep 1" INT; sudo tail -f -n50 "$log_path" || true; trap - INT; }
view_docker_logs(){ local compose_path="$1"; local name="$2"; if [ -z "$compose_path" ] || [ ! -f "$compose_path" ]; then echo -e "${C_RED}Путь не найден.${C_RESET}"; sleep 2; return; fi; echo "[*] Просмотр логов $name"; trap "echo; echo -e '${C_GREEN}Возвращаюсь...${C_RESET}'; sleep 1" INT; (cd "$(dirname "$compose_path")" && sudo docker compose logs -f) || true; trap - INT; }

security_placeholder(){ clear; echo -e "${C_RED}В РАЗРАБОТКЕ${C_RESET}"; }

uninstall_script(){ echo -e "${C_RED}Точно удалить?${C_RESET}"; read -p "Это снесёт скрипт и конфиги. (y/n): " c; if [[ "$c" != "y" && "$c" != "Y" ]]; then echo "Отмена"; wait_for_enter; return; fi
    sudo rm -f "$INSTALL_PATH" || true; sudo sed -i "/alias reshala=/d" /root/.bashrc || true; rm -f "$CONFIG_FILE" || true; sudo rm -f "$LOGFILE" || true; echo -e "${C_GREEN}Удалено.${C_RESET}"; exit 0; }

# ----------------- UI / MENU -----------------
display_header(){
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "n/a");
    local net_status; net_status=$(get_net_status); local cc; cc=$(echo "$net_status" | cut -d'|' -f1); local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2)
    local cc_status="${C_YELLOW}СТОК ($cc)${C_RESET}"
    if [[ "$cc" == "bbr" || "$cc" == "bbr2" || "$cc" == "bbr3" ]]; then
        if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}МАКСИМУМ ($cc + cake)${C_RESET}"; else cc_status="${C_GREEN}АКТИВЕН ($cc + $qdisc)${C_RESET}"; fi
    fi
    local ipv6_status; ipv6_status=$(check_ipv6_status)
    local cpu_info; cpu_info=$(get_cpu_info); local cpu_load; cpu_load=$(get_cpu_load); local ram_info; ram_info=$(get_ram_info); local disk_info; disk_info=$(get_disk_info); local hoster_info; hoster_info=$(get_hoster_info)

    clear
    echo -e "${C_CYAN}╔═[ РЕШАЛА ${VERSION} ]${C_RESET}"
    echo -e "${C_CYAN}╠═[ ИНФО ]${C_RESET}"
    printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "IP" "$ip_addr"
    printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Хостер" "$hoster_info"
    printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "CPU" "$cpu_info"
    printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Нагрузка" "$cpu_load"
    printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "RAM" "$ram_info"
    printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "DISK" "$disk_info"

    echo -e "${C_CYAN}╠═[ СТАТУС ]${C_RESET}"
    if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE v$PANEL_NODE_VERSION"; else printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE"; fi
    if [ "$BOT_DETECTED" -eq 1 ]; then printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Бот" "$BOT_VERSION"; fi
    if [[ "$WEB_SERVER" != "Не определён" ]]; then printf "║ ${C_GRAY}%-11s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Веб-сервер" "$WEB_SERVER"; fi

    echo -e "${C_CYAN}╠═[ СЕТЬ ]${C_RESET}"
    printf "║ ${C_GRAY}%-11s${C_RESET} : %b\n" "Тюнинг" "$cc_status"
    printf "║ ${C_GRAY}%-11s${C_RESET} : %b\n" "IPv6" "$ipv6_status"
    echo -e "${C_CYAN}╚${C_RESET}"
}

show_menu(){
    while true; do
        scan_server_state
        display_header
        check_for_updates || true
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then echo -e "\n${C_YELLOW}🔥 Новая версия: ${LATEST_VERSION}${C_RESET}"; fi

        echo -e "\nВыбери действие:\n"
        echo " 1) Управление "Форсаж" (BBR/CAKE)"
        echo " 2) Управление IPv6"
        echo " 3) Просмотр лога Форсажа"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo " 4) Просмотр логов Бота"; fi
        if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then echo " 5) Просмотр логов $SERVER_TYPE"; fi
        echo " 6) Безопасность (в разработке)"
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then echo " u) Обновить Решалу"; fi
        echo " d) Удалить Решалу"
        echo " q) Выход"
        read -r -p "Выбор: " choice
        case $choice in
            1) apply_bbr; wait_for_enter;;
            2) ipv6_menu;;
            3) view_logs_realtime "$LOGFILE" "Форсажа";;
            4) [ "$BOT_DETECTED" -eq 1 ] && view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота" || (echo "Нет бота"; sleep 1);;
            5) [[ "$SERVER_TYPE" != "Чистый сервак" ]] && view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE" || (echo "Нет панели"; sleep 1);;
            6) security_placeholder; wait_for_enter;;
            u|U) [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]] && run_update || (echo "Нет обновлений"; sleep 1);;
            d|D) uninstall_script;;
            q|Q) echo "Пока"; break;;
            *) echo "Неверный выбор"; sleep 1;;
        esac
    done
}

# IPv6 меню вынесено, чтобы избежать дублирования
ipv6_menu(){
    while true; do clear; echo "--- IPv6 ---"; echo -e "Статус: $(check_ipv6_status)"; echo "1) Отключить"; echo "2) Включить"; echo "b) Назад"; read -r -p "Выбор: " ch; case $ch in 1) disable_ipv6; wait_for_enter;; 2) enable_ipv6; wait_for_enter;; b|B) break;; *) echo "1,2 или b"; sleep 1;; esac; done
}

# ----------------- MAIN -----------------
if [[ "${1:-}" == "install" ]]; then
    if [[ $EUID -ne 0 ]]; then echo -e "${C_RED}Запуск установки требует root.${C_RESET}"; exit 1; fi
    echo "Устанавливаю..."; sudo cp -- "$0" "$INSTALL_PATH" && sudo chmod +x "$INSTALL_PATH"; echo "Установлено в $INSTALL_PATH"; exit 0
else
    if [[ $EUID -ne 0 ]]; then echo -e "${C_RED}Запускай с sudo.${C_RESET}"; exit 1; fi
    trap - INT TERM EXIT
    show_menu
fi
