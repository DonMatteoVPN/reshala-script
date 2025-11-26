#!/bin/bash
# ============================================================ #
# ==             МОДУЛЬ ОБСЛУЖИВАНИЯ СИСТЕМЫ                == #
# ============================================================ #
#
# Этот модуль — механик. Он крутит гайки в локальной системе:
# обновляет пакеты, тюнингует сеть, меряет скорость.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# ============================================================ #
#                  СЕТЕВОЙ ТЮНИНГ (BBR/CAKE/IPv6)              #
# ============================================================ #
_get_net_status() {
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")
    local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a")
    if [[ "$qdisc" == "pfifo_fast" ]]; then
        local tc_qdisc; tc_qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n1)
        [[ -n "$tc_qdisc" ]] && qdisc="$tc_qdisc"
    fi
    echo "${cc}|${qdisc}"
}

_apply_bbr() {
    log "Запуск тюнинга сети (BBR/CAKE)..."
    local net_status=$(_get_net_status); local current_cc=$(echo "$net_status"|cut -d'|' -f1); local current_qdisc=$(echo "$net_status"|cut -d'|' -f2)
    local cake_available; modprobe sch_cake &>/dev/null && cake_available="true" || cake_available="false"

    echo "--- ДИАГНОСТИКА ТВОЕГО ДВИГАТЕЛЯ ---"
    echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"
    echo "------------------------------------"
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then
        printf_ok "Ты уже на максимальном форсаже. Не мешай машине работать."
        wait_for_enter
        return
    fi
    if ! ask_yes_no "Хочешь включить максимальный форсаж (BBR + CAKE)? (y/n): " "n"; then
        echo "Как скажешь."
        return
    fi

    local preferred_cc="bbr"; [[ $(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null) == *"bbr2"* ]] && preferred_cc="bbr2"
    local preferred_qdisc="fq"; [[ "$cake_available" == "true" ]] && preferred_qdisc="cake"
    
    local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"
    printf_info "✍️  Устанавливаю новые, пиздатые настройки..."
    run_cmd tee "$CONFIG_SYSCTL" >/dev/null <<EOF
# === КОНФИГ «ФОРСАЖ» ОТ РЕШАЛЫ — НЕ ТРОГАТЬ ===
net.core.default_qdisc = ${preferred_qdisc}
net.ipv4.tcp_congestion_control = ${preferred_cc}
net.ipv4.tcp_fastopen = 3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
    printf_info "🔥 Применяю настройки..."
    run_cmd sysctl -p "$CONFIG_SYSCTL" >/dev/null
    printf_ok "Твоя тачка теперь — ракета. (CC: ${preferred_cc}, QDisc: ${preferred_qdisc})"
    wait_for_enter
}

# Отдельная функция, которая ТОЛЬКО возвращает статус для дашборда
_get_ipv6_status_string() {
    if [[ ! -d "/proc/sys/net/ipv6" ]]; then echo "${C_RED}ВЫРЕЗАН${C_RESET}"
    elif [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" -eq 1 ]]; then echo "${C_RED}КАСТРИРОВАН${C_RESET}"
    else echo "${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi
}

_toggle_ipv6() {
    enable_graceful_ctrlc
    while true; do
        clear; echo "--- УПРАВЛЕНИЕ IPv6 ---"; printf "Статус IPv6: %b\n" "$(_get_ipv6_status_string)"
        echo "--------------------------"; echo "   1. Кастрировать (Отключить)"; echo "   2. Реанимировать (Включить)"; echo "   b. Назад"
        local choice; read -r -p "Твой выбор: " choice
        case "$choice" in
            1) run_cmd tee /etc/sysctl.d/98-disable-ipv6.conf >/dev/null <<< "net.ipv6.conf.all.disable_ipv6 = 1"; run_cmd sysctl -p /etc/sysctl.d/98-disable-ipv6.conf >/dev/null; printf_ok "IPv6 кастрирован."; sleep 1 ;;
            2) run_cmd rm -f /etc/sysctl.d/98-disable-ipv6.conf; run_cmd tee /etc/sysctl.d/98-enable-ipv6.conf >/dev/null <<< "net.ipv6.conf.all.disable_ipv6 = 0"; run_cmd sysctl -p /etc/sysctl.d/98-enable-ipv6.conf >/dev/null; run_cmd rm -f /etc/sysctl.d/98-enable-ipv6.conf; printf_ok "IPv6 реанимирован."; sleep 1 ;;
            [bB]) break ;;
        esac
    done
    disable_graceful_ctrlc
}

# ============================================================ #
#               ОБНОВЛЕНИЕ СИСТЕМЫ (APT + EOL FIX)             #
# ============================================================ #

_run_system_update() {
    if ! command -v apt-get &>/dev/null; then
        printf_error "Это не Debian/Ubuntu. Я тут бессилен."
        return
    fi
    clear
    printf_info "ЦЕНТР ОБНОВЛЕНИЯ И РЕАНИМАЦИИ СИСТЕМЫ"
    echo "1. Проверю интернет."
    echo "2. Попробую стандартный 'apt update'."
    echo "3. Если ошибка 404 (EOL) - предложу переключиться на архивные репозитории."
    echo "---------------------------------------------------------------------"

    printf "[*] Проверяю связь с внешним миром... "
    if ! curl -s --connect-timeout 3 google.com >/dev/null; then
        printf "%b\n" "${C_RED}Связи нет!${C_RESET}"
        printf_error "Проверь DNS или кабель. Без интернета обновлений не будет."
        return
    fi
    printf "%b\n" "${C_GREEN}Есть контакт.${C_RESET}"

    printf_info "[*] Попытка стандартного обновления (apt update)..."
    if run_cmd apt-get update; then
        printf_ok "Отлично! Официальные зеркала доступны. Запускаю полное обновление..."
        run_cmd apt-get upgrade -y
        run_cmd apt-get full-upgrade -y
        run_cmd apt-get autoremove -y
        run_cmd apt-get autoclean -y
        printf_ok "Система полностью обновлена."
        log "Обновление системы (Standard) успешно."
    else
        printf_error "ОШИБКА ОБНОВЛЕНИЯ! Похоже, твоя версия ОС устарела (EOL)."
        echo "Это значит, что стандартные репозитории больше не доступны."
        if ask_yes_no "🚑 Применить лечение (переключиться на архивные репозитории)? (y/n): " "n"; then
            log "Запуск процедуры EOL Fix..."
            local backup_dir="/var/backups/reshala_apt_$(date +%F)"
            printf_info "Делаю бэкап конфигов в ${backup_dir}..."
            run_cmd mkdir -p "$backup_dir"
            run_cmd cp /etc/apt/sources.list "$backup_dir/"
            
            printf_info "🔧 Исправляю адреса серверов..."
            run_cmd sed -i -r 's/([a-z]{2}\.)?archive.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
            run_cmd sed -i -r 's/security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
            
            printf_info "Пробую обновиться снова с архивных репозиториев..."
            if run_cmd apt-get update; then
                printf_ok "ПОЛУЧИЛОСЬ! Запускаю полное обновление..."
                run_cmd apt-get upgrade -y; run_cmd apt-get full-upgrade -y; run_cmd apt-get autoremove -y;
                printf_ok "EOL Fix сработал, всё обновлено. Живём!"
                log "Обновление системы (EOL fix) успешно завершено."
            else
                printf_error "Не прокатило. Пациент скорее мёртв. Возвращаю бэкап."
                run_cmd cp "$backup_dir/sources.list" /etc/apt/
                log "Обновление после EOL fix не удалось."
            fi
        fi
    fi
    wait_for_enter
}

# ============================================================ #
#                           SPEEDTEST                          #
# ============================================================ #

# Калькулятор вместимости ноды (портирован из старого монолита)
_calculate_vpn_capacity() {
    local upload_speed="$1"  # В Мбит/с

    local ram_total; ram_total=$(free -m | grep Mem | awk '{print $2}')
    local ram_used;  ram_used=$(free -m | grep Mem | awk '{print $3}')
    local cpu_cores; cpu_cores=$(nproc)

    local available_ram=$((ram_total - ram_used - 250))
    if [ "$available_ram" -lt 0 ]; then available_ram=0; fi

    local max_users_ram=$((available_ram / 4))
    local max_users_cpu=$((cpu_cores * 600))

    local hw_limit=$max_users_ram
    local hw_reason="RAM"
    if [ "$max_users_cpu" -lt "$max_users_ram" ]; then
        hw_limit=$max_users_cpu
        hw_reason="CPU"
    fi

    if [ -n "$upload_speed" ]; then
        local clean_speed=${upload_speed%.*}
        local net_limit
        net_limit=$(awk "BEGIN {printf \"%.0f\", $clean_speed * 0.8}")
        if [ "$net_limit" -lt "$hw_limit" ]; then
            echo "$net_limit (Упор в Канал)"
        else
            echo "$hw_limit (Упор в $hw_reason)"
        fi
    else
        echo "$hw_limit (Лимит $hw_reason)"
    fi
}

# Вспомогательный хелпер: установка официального клиента Speedtest от Ookla
_install_official_speedtest() {
    if ! command -v apt-get &>/dev/null; then
        err "apt-get не найден. Не могу автоматически установить официальный speedtest."
        return 1
    fi

    printf_info "Ставлю официальный Speedtest от Ookla (через packagecloud)..."
    # Скрипт репозитория может уже быть применён — это окей
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | run_cmd bash >/dev/null 2>&1 || true
    run_cmd apt-get update -qq >/dev/null 2>&1 || true
    run_cmd apt-get install -y speedtest >/dev/null 2>&1 || {
        err "Не удалось установить пакет speedtest. Проверь репозитории вручную."
        return 1
    }
    return 0
}

# Детектор/чистильщик кривых speedtest (не-Ookla, битый бинарь, snap и т.п.)
_cleanup_broken_speedtest() {
    local bin_path
    bin_path=$(command -v speedtest 2>/dev/null || true)

    # Пробуем аккуратно удалить известные пакеты speedtest/speedtest-cli
    if command -v dpkg &>/dev/null; then
        if dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]+speedtest-cli[[:space:]]'; then
            run_cmd apt-get remove -y speedtest-cli >/dev/null 2>&1 || true
        fi
        if dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]+speedtest[[:space:]]'; then
            run_cmd apt-get remove -y speedtest >/dev/null 2>&1 || true
        fi
    fi

    # Если стоял snap-овский speedtest — убираем и его
    if command -v snap &>/dev/null; then
        if snap list 2>/dev/null | grep -q '^speedtest\b'; then
            run_cmd snap remove speedtest >/dev/null 2>&1 || true
        fi
    fi

    # Если после этого бинарь всё ещё есть в PATH — пробуем удалить файл руками
    if command -v speedtest &>/dev/null 2>&1; then
        bin_path=$(command -v speedtest 2>/dev/null || true)
        if [[ -n "$bin_path" && -x "$bin_path" ]]; then
            warn "Speedtest по-прежнему в PATH ($bin_path). Пробую удалить бинарь руками..."
            run_cmd rm -f "$bin_path" || true
        fi
    fi
}

# Главный хелпер: убедиться, что стоит именно официальный Speedtest от Ookla
_ensure_speedtest_ok() {
    ensure_package "curl"

    if ! command -v speedtest &>/dev/null; then
        _install_official_speedtest
        return
    fi

    # Проверяем версию: у официального клиента в версии фигурирует строка "Speedtest by Ookla"
    local ver_out
    ver_out=$(speedtest --version 2>/dev/null | head -n1 || true)

    if [[ -z "$ver_out" ]]; then
        warn "Speedtest установлен, но не отвечает на --version. Попробую переустановить."
        _cleanup_broken_speedtest
        _install_official_speedtest
        return
    fi

    if [[ "$ver_out" != *"Ookla"* ]]; then
        warn "Обнаружен нестандартный speedtest ('$ver_out'). Переставляю официальный клиент."
        _cleanup_broken_speedtest
        _install_official_speedtest
    fi
}

_run_speedtest() {
    clear
    printf_info "🚀 ЗАПУСКАЮ ТЕСТ СКОРОСТИ ДО МОСКВЫ..."

    ensure_package "jq"
    _ensure_speedtest_ok

    if ! command -v speedtest &>/dev/null; then
        printf_error "Speedtest так и не установился автоматически. Проверь интернет и репозитории."
        wait_for_enter
        return
    fi

    printf_warning "РУКИ УБРАЛ ОТ КЛАВИАТУРЫ! Идёт замер..."
    local json_output; json_output=$(speedtest --accept-license --accept-gdpr --server-id "$SPEEDTEST_DEFAULT_SERVER_ID" -f json 2>/dev/null)

    if [[ -z "$json_output" ]]; then
        printf_warning "Сервер по умолчанию недоступен. Ищу любой другой..."
        json_output=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null)
    fi

    if [[ -n "$json_output" ]]; then
        local ping;     ping=$(echo "$json_output" | jq -r '.ping.latency')
        local dl_bytes; dl_bytes=$(echo "$json_output" | jq -r '.download.bandwidth')
        local ul_bytes; ul_bytes=$(echo "$json_output" | jq -r '.upload.bandwidth')
        local url;      url=$(echo "$json_output" | jq -r '.result.url')

        local dl_mbps; dl_mbps=$(awk "BEGIN {printf \"%.2f\", $dl_bytes * 8 / 1000000}")
        local ul_mbps; ul_mbps=$(awk "BEGIN {printf \"%.2f\", $ul_bytes * 8 / 1000000}")

        echo "══════════════════════════════════════════════════"
        printf "   %bPING:%b      %.2f ms\n" "${C_GRAY}" "${C_RESET}" "$ping"
        printf "   %bСКАЧКА:%b    %s Mbit/s\n" "${C_GREEN}" "${C_RESET}" "$dl_mbps"
        printf "   %bОТДАЧА:%b    %s Mbit/s\n" "${C_CYAN}" "${C_RESET}" "$ul_mbps"
        echo "══════════════════════════════════════════════════"
        echo "   🔗 Линк на результат: $url"

        log "Speedtest: DL=${dl_mbps}, UL=${ul_mbps}, Ping=${ping}"

        # Сохраняем аплоад и расчётную вместимость в конфиг, чтобы дашборд знал, на что способен сервер
        local clean_ul_int
        clean_ul_int=$(echo "$ul_mbps" | cut -d'.' -f1)
        if [[ "$clean_ul_int" =~ ^[0-9]+$ ]] && [ "$clean_ul_int" -gt 0 ]; then
            local capacity
            capacity=$(_calculate_vpn_capacity "$ul_mbps")
            set_config_var "LAST_UPLOAD_SPEED" "$clean_ul_int"
            set_config_var "LAST_VPN_CAPACITY" "$capacity"

            printf "\n%b💎 ВЕРДИКТ РЕШАЛЫ:%b\n" "${C_BOLD}" "${C_RESET}"
            printf "   С таким каналом эта нода потянет примерно: %b%s юзеров%b\n" "${C_GREEN}" "$capacity" "${C_RESET}"
            echo "   (Результат сохранён для главного меню/дашборда)"
        fi
    else
        printf_error "Ошибка: Speedtest вернул пустоту. Попробуй позже."
    fi
    wait_for_enter
}

# ============================================================ #
#                ГЛАВНОЕ МЕНЮ ОБСЛУЖИВАНИЯ                     #
# ============================================================ #
_set_dashboard_profile_menu() {
    while true; do
        clear
        menu_header "Профиль нагрузки дашборда"
        echo
        echo "   Тут настраиваем, как часто дашборд будет трогать систему и сеть."
        echo "   Профиль влияет на TTL кэша основных метрик и виджетов."
        echo

        local current
        current=$(get_config_var "DASHBOARD_LOAD_PROFILE")
        if [[ -z "$current" ]]; then
            current="normal"
        fi

        local mark_normal=" " mark_light=" " mark_ultra=" "
        case "$current" in
            normal)      mark_normal="*" ;;
            light)       mark_light="*" ;;
            ultra_light) mark_ultra="*" ;;
        esac

        echo "   [1] ($mark_normal) NORMAL      — стандартный режим (база: 25/60 сек)"
        echo "   [2] ($mark_light)  LIGHT       — реже обновление (примерно x2: ~50/120)"
        echo "   [3] ($mark_ultra) ULTRA_LIGHT — минимальная нагрузка (примерно x4: ~100/240)"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "")

        case "$choice" in
            1)
                set_config_var "DASHBOARD_LOAD_PROFILE" "normal"
                ok "Профиль дашборда: NORMAL. Изменения применятся при следующем открытии панели."
                sleep 1
                ;;
            2)
                set_config_var "DASHBOARD_LOAD_PROFILE" "light"
                ok "Профиль дашборда: LIGHT. Метрики и виджеты будут обновляться реже."
                sleep 1
                ;;
            3)
                set_config_var "DASHBOARD_LOAD_PROFILE" "ultra_light"
                ok "Профиль дашборда: ULTRA_LIGHT. Минимум нагрузки, максимум кеша."
                sleep 1
                ;;
            [bB])
                return
                ;;
            *)
                err "Нет такого пункта, смотри внимательнее, босс."
                ;;
        esac
    done
}

show_maintenance_menu() {
    while true; do
        clear
        menu_header "🔧 СЕРВИСНОЕ ОБСЛУЖИВАНИЕ (КРУТИМ ГАЙКИ)"
        echo ""
        echo "   [1] 🔄 Обновить систему + Лечение EOL (Ubuntu Fix)"
        echo "   [2] 🚀 Настройка сети «Форсаж» (BBR + CAKE)"
        echo "   [3] 🌐 Управление IPv6 (Вкл/Выкл)"
        echo "   [4] ⚡ Тест скорости до Москвы (Speedtest)"
        echo "   [5] 🎛 Профиль нагрузки дашборда (NORMAL/LIGHT/ULTRA)"
        echo ""
        echo "   [b] 🔙 Назад в главное меню"
        echo "------------------------------------------------------"
        
        local choice; choice=$(safe_read "Твой выбор: " "")

        case "$choice" in
            1) _run_system_update ;;
            2) _apply_bbr ;;
            3) _toggle_ipv6 ;;
            4) _run_speedtest ;;
            5) _set_dashboard_profile_menu ;;
            [bB]) break ;;
            *) ;;
        esac
    done
}
