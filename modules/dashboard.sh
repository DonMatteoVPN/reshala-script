#!/bin/bash
# ============================================================ #
# ==             МОДУЛЬ ИНФОРМАЦИОННОЙ ПАНЕЛИ               == #
# ============================================================ #
#
# Этот модуль — твои глаза. Он собирает всю инфу о системе
# и красиво её отрисовывает. Теперь с поддержкой виджетов!
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# ============================================================ #
#          БЛОК СБОРА ИНФОРМАЦИИ О СИСТЕМЕ И ЖЕЛЕЗЕ           #
# ============================================================ #
# ... (весь блок _get_os_ver, _get_kernel и т.д. из предыдущего ответа)
# ЭТА ЧАСТЬ НЕ МЕНЯЕТСЯ, ПРОСТО СКОПИРУЙ ЕЁ СЮДА КАК БЫЛА

_get_os_ver() { grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo "Linux"; }
_get_kernel() { uname -r | cut -d'-' -f1; }
_get_uptime() { uptime -p | sed 's/up //;s/ hours\?,/ч/;s/ minutes\?/мин/;s/ days\?,/д/;s/ weeks\?,/нед/'; }
_get_virt_type() {
    local virt; virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    case "$virt" in
        kvm|qemu) echo "KVM (Честное железо)" ;;
        lxc|openvz) echo "Container ($virt) - ⚠️" ;;
        none) echo "Bare Metal (Дед)" ;;
        *) echo "${virt^}" ;;
    esac
}
_get_public_ip() { curl -s --connect-timeout 4 -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }
_get_location() { curl -s --connect-timeout 2 ipinfo.io/country 2>/dev/null || echo "??"; }
_get_hoster_info() { curl -s --connect-timeout 5 ipinfo.io/org 2>/dev/null || echo "Не определён"; }
_get_active_users() { who | cut -d' ' -f1 | sort -u | wc -l; }
_get_ping_google() {
    local p; p=$(ping -c 1 -W 1 8.8.8.8 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | cut -d' ' -f1)
    [[ -z "$p" ]] && echo "OFFLINE ❌" || echo "${p} ms ⚡"
}

_get_cpu_info_clean() {
    local model; model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/(R)//g; s/(TM)//g; s/ @.*//g; s/CPU//g' | xargs)
    [[ -z "$model" ]] && model=$(lscpu | grep "Model name" | sed -r 's/.*:\s+//' | sed 's/ @.*//')
    echo "$model" | cut -c 1-35 # Обрезаем, чтобы не ломать вёрстку
}

_draw_bar() {
    local perc=$1; local size=10
    local bar_perc=$perc; [[ "$bar_perc" -gt 100 ]] && bar_perc=100
    local filled=$(( bar_perc * size / 100 )); local empty=$(( size - filled ))
    local color="${C_GREEN}"; [[ "$perc" -ge 70 ]] && color="${C_YELLOW}"; [[ "$perc" -ge 90 ]] && color="${C_RED}"
    printf "${C_GRAY}["; printf "${color}"; for ((i=0; i<filled; i++)); do printf "■"; done
    printf "${C_GRAY}"; for ((i=0; i<empty; i++)); do printf "□"; done
    printf "${C_GRAY}] ${color}%3s%%${C_RESET}" "$perc"
}

_get_cpu_load_visual() {
    local cores; cores=$(nproc)
    local load; load=$(uptime | awk -F'load average: ' '{print $2}' | cut -d, -f1 | xargs)
    local perc; perc=$(awk "BEGIN {printf \"%.0f\", ($load / $cores) * 100}")
    local bar; bar=$(_draw_bar "$perc")
    echo "$bar ($load / $cores vCore)"
}

_get_ram_visual() {
    local ram_info; ram_info=$(free -m | grep Mem)
    local ram_used; ram_used=$(echo "$ram_info" | awk '{print $3}')
    local ram_total; ram_total=$(echo "$ram_info" | awk '{print $2}')
    if [ "$ram_total" -eq 0 ]; then echo "N/A"; return; fi
    local perc=$(( 100 * ram_used / ram_total ))
    local bar; bar=$(_draw_bar "$perc")
    local used_str; local total_str
    if [ "$ram_total" -gt 1024 ]; then
        used_str=$(awk "BEGIN {printf \"%.1fG\", $ram_used/1024}")
        total_str=$(awk "BEGIN {printf \"%.1fG\", $ram_total/1024}")
    else
        used_str="${ram_used}M"; total_str="${ram_total}M"
    fi
    echo "$bar ($used_str / $total_str)"
}

_get_disk_visual() {
    local main_disk; main_disk=$(df / | awk 'NR==2 {print $1}' | sed 's|/dev/||' | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
    local disk_type="HDD"
    if [ -f "/sys/block/$main_disk/queue/rotational" ] && [ "$(cat "/sys/block/$main_disk/queue/rotational")" -eq 0 ]; then
        disk_type="SSD"; elif [[ "$main_disk" == *"nvme"* ]]; then disk_type="SSD"; fi
    local usage_stats; usage_stats=$(df -h / | awk 'NR==2 {print $3 "/" $2}')
    local perc_str; perc_str=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    local bar; bar=$(_draw_bar "$perc_str")
    echo "$disk_type|$bar ($usage_stats)"
}

# Скорость линка (если удаётся вытащить аккуратно)
_get_port_speed() {
    local iface; iface=$(ip route | grep default | head -n1 | awk '{print $5}')
    local speed=""

    if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/speed" ]; then
        local raw; raw=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
        if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -gt 0 ]; then
            speed="${raw}Mbps"
        fi
    fi

    if [ -z "$speed" ] && command -v ethtool &>/dev/null && [ -n "$iface" ]; then
        speed=$(ethtool "$iface" 2>/dev/null | grep "Speed:" | awk '{print $2}')
    fi

    if [[ -z "$speed" ]] || [[ "$speed" == "Unknown!" ]]; then
        return
    fi

    if [ "$speed" == "1000Mbps" ];  then speed="1 Gbps";  fi
    if [ "$speed" == "10000Mbps" ]; then speed="10 Gbps"; fi
    if [ "$speed" == "2500Mbps" ];  then speed="2.5 Gbps"; fi

    echo "$speed"
}

# ============================================================ #
#                  ГЛАВНАЯ ФУНКЦИЯ ОТРИСОВКИ                   #
# ============================================================ #
show() {
    clear

    # Обновляем картину мира Remnawave/бота перед отрисовкой панели
    # (модуль state_scanner портирован из старого монолита)
    if command -v run_module &>/dev/null; then
        run_module state_scanner scan_remnawave_state
    fi

    # --- Сбор данных ---
    local os_ver=$(_get_os_ver); local kernel=$(_get_kernel)
    local uptime=$(_get_uptime); local users_online=$(_get_active_users)
    local virt=$(_get_virt_type)
    local ip_addr=$(_get_public_ip); local location=$(_get_location); local ping=$(_get_ping_google)
    local hoster_info=$(_get_hoster_info)
    local cpu_info=$(_get_cpu_info_clean); local cpu_load_viz=$(_get_cpu_load_visual)
    local ram_viz=$(_get_ram_visual)
    local disk_raw=$(_get_disk_visual); local disk_type=$(echo "$disk_raw" | cut -d'|' -f1); local disk_viz=$(echo "$disk_raw" | cut -d'|' -f2)
    local port_speed; port_speed=$(_get_port_speed)

    # Вместимость / канал (если когда-то гоняли speedtest)
    local saved_speed; saved_speed=$(get_config_var "LAST_UPLOAD_SPEED")
    local capacity_display=""
    if [[ -n "$saved_speed" ]]; then
        # Сохраняем уже готовую строку, чтобы не дёргать железо лишний раз
        capacity_display=$(get_config_var "LAST_VPN_CAPACITY")
    fi

    # --- Заголовок ---
    if [ "${SKYNET_MODE:-0}" -eq 1 ]; then
        printf "%b\n" "${C_RED}╔════════════════════════════════════════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_RED}║   👁️  ПОДКЛЮЧЕН ЧЕРЕЗ SKYNET (УДАЛЕННОЕ УПРАВЛЕНИЕ) 👁️    ║${C_RESET}"
        printf "%b\n" "${C_RED}╚════════════════════════════════════════════════════════════════╝${C_RESET}"
    else
        printf "%b\n" "${C_CYAN}╔═[ ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ]═════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_CYAN}║${C_RESET}"
    fi

    # --- Секция "Система" ---
    printf "%b\n" "${C_CYAN}╠═[ СИСТЕМА ]${C_RESET}"
    printf "║ %b%-*s${C_RESET} : %b%s (%s)%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "ОС / Ядро" "${C_WHITE}" "$os_ver" "$kernel" "${C_RESET}"
    printf "║ %b%-*s${C_RESET} : %b%s (Юзеров: %s)%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Аптайм" "${C_WHITE}" "$uptime" "$users_online" "${C_RESET}"
    printf "║ %b%-*s${C_RESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Виртуализация" "${C_CYAN}" "$virt" "${C_RESET}"
    printf "║ %b%-*s${C_RESET} : %b%s%b (%s) [%b%s%b]\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "IP Адрес" "${C_YELLOW}" "$ip_addr" "${C_RESET}" "$ping" "${C_CYAN}" "$location" "${C_RESET}"
    printf "║ %b%-*s${C_RESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Хостер" "${C_CYAN}" "$hoster_info" "${C_RESET}"
    
    printf "%b\n" "${C_CYAN}║${C_RESET}"

    # --- Секция "Железо" ---
    printf "%b\n" "${C_CYAN}╠═[ ЖЕЛЕЗО ]${C_RESET}"
    printf "║ %b%-*s${C_RESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "CPU Модель" "${C_WHITE}" "$cpu_info" "${C_RESET}"
    printf "║ %b%-*s${C_RESET} : %s\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Загрузка CPU" "$cpu_load_viz"
    printf "║ %b%-*s${CRESET} : %s\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Память (RAM)" "$ram_viz"
    printf "║ %b%-*s${C_RESET} : %s\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Диск (${disk_type})" "$disk_viz"

    printf "%b\n" "${C_CYAN}║${C_RESET}"
    
    # --- Секция "Статус" ---
    printf "%b\n" "${C_CYAN}╠═[ STATUS ]${C_RESET}"

    # Remnawave / Нода / Бот (данные даёт state_scanner)
    if [[ "$SERVER_TYPE" == "Панель и Нода" ]]; then
        printf "║ %b%-*s${CRESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Remnawave" "${C_GREEN}" "🔥 COMBO (Панель + Нода)" "${C_RESET}"
        printf "║ %b%-*s${CRESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Версии" "${C_WHITE}" "P: v${PANEL_VERSION} | N: v${NODE_VERSION}" "${C_RESET}"
    elif [[ "$SERVER_TYPE" == "Панель" ]]; then
        printf "║ %b%-*s${CRESET} : %b%s%b (v%s)\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Remnawave" "${C_GREEN}" "Панель управления" "${C_RESET}" "${PANEL_VERSION}"
    elif [[ "$SERVER_TYPE" == "Нода" ]]; then
        printf "║ %b%-*s${CRESET} : %b%s%b (v%s)\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Remnawave" "${C_GREEN}" "Боевая Нода" "${C_RESET}" "${NODE_VERSION}"
    elif [[ "$SERVER_TYPE" == "Сервак не целка" ]]; then
        printf "║ %b%-*s${CRESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Remnawave" "${C_RED}" "НЕ НАЙДЕНО / СТОРОННИЙ СОФТ" "${C_RESET}"
    else
        printf "║ %b%-*s${CRESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Remnawave" "${C_WHITE}" "Не установлена" "${C_RESET}"
    fi

    if [ "${BOT_DETECTED:-0}" -eq 1 ]; then
        printf "║ %b%-*s${CRESET} : %b%s%b (v%s)\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Bedalaga" "${C_CYAN}" "АКТИВЕН" "${C_RESET}" "${BOT_VERSION}"
    fi

    if [[ "$WEB_SERVER" != "Не определён" ]]; then
        printf "║ %b%-*s${C_RESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Web-Server" "${C_CYAN}" "$WEB_SERVER" "${C_RESET}"
    fi

    if [[ -n "$port_speed" ]]; then
        printf "║ %b%-*s${C_RESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Канал (Link)" "${C_BOLD}" "$port_speed" "${C_RESET}"
    fi

    # Если есть сохранённая вместимость — покажем её, чтобы боссу было приятно
    if [[ -n "$capacity_display" ]]; then
        printf "║ %b%-*s${C_RESET} : %b%s%b юзеров\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "Вместимость" "${C_GREEN}" "$capacity_display" "${C_RESET}"
    fi

    printf "%b\n" "${C_CYAN}║${C_RESET}"

    # ======================================================= #
    # === НОВЫЙ БЛОК: ДИНАМИЧЕСКИЕ ВИДЖЕТЫ С ПЕРЕКЛЮЧАТЕЛЕМ = #
    # ======================================================= #
    local WIDGETS_DIR="${SCRIPT_DIR}/plugins/dashboard_widgets"
    # Получаем список ВКЛЮЧЕННЫХ виджетов из конфига
    local enabled_widgets; enabled_widgets=$(get_config_var "ENABLED_WIDGETS")

    if [ -d "$WIDGETS_DIR" ] && [ -n "$enabled_widgets" ]; then
        local has_visible_widgets=0
        
        # Проходим по всем исполняемым файлам в папке виджетов
        for widget_file in "$WIDGETS_DIR"/*.sh; do
            if [ -f "$widget_file" ] && [ -x "$widget_file" ]; then
                local widget_name; widget_name=$(basename "$widget_file")
                
                # Проверяем, есть ли имя этого виджета в списке включенных
                if [[ ",$enabled_widgets," == *",$widget_name,"* ]]; then
                    # Если это первый видимый виджет, рисуем заголовок
                    if [ $has_visible_widgets -eq 0 ]; then
                        printf "%b\n" "${C_CYAN}║${C_RESET}"
                        printf "%b\n" "${C_CYAN}╠═[ WIDGETS ]${C_RESET}"
                        has_visible_widgets=1
                    fi

                    local widget_output; widget_output=$("$widget_file")
                    while IFS= read -r line; do
                        local label; label=$(echo "$line" | cut -d':' -f1 | xargs)
                        local value; value=$(echo "$line" | cut -d':' -f2- | xargs)
                        printf "║ %b%-*s${C_RESET} : %b%s%b\n" "${C_GRAY}" "${DASHBOARD_LABEL_WIDTH}" "$label" "${C_CYAN}" "$value" "${C_RESET}"
                    done <<< "$widget_output"
                fi
            fi
        done
    fi
    # ======================================================= #
    # === КОНЕЦ БЛОКА ВИДЖЕТОВ ================================ #
    # ======================================================= #

    printf "%b\n" "${C_CYAN}╚════════════════════════════════════════════════════════════════╝${C_RESET}"
}