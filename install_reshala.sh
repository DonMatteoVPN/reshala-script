#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v0.26 - РАБОТА НАД ОШИБКАМИ     ==
# ============================================================ #
# ==       Теперь он сам себя обновляет и чинит.             ==
# ============================================================ #

set -euo pipefail

# --- КОНСТАНТЫ И ПЕРЕМЕННЫЕ ---
readonly VERSION="v0.26"
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/install_reshala.sh"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala_ops.log"
INSTALL_PATH="/usr/local/bin/reshala"

# Цвета
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m';

# --- УТИЛИТАРНЫЕ ФУНКЦИИ ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | sudo tee -a "$LOGFILE"; }
wait_for_enter() { read -p $'\nНажми Enter, если закончил...'; }
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

    echo -e "\n${C_GREEN}✅ ИНТЕГРАЦИЯ ЗАВЕРШЕНА.${C_RESET}\n"
    
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

# --- МОДУЛЬ ОБНОВЛЕНИЯ ---
check_for_updates() {
    LATEST_VERSION=$(wget -qO- "$SCRIPT_URL" 2>/dev/null | grep -m 1 'readonly VERSION' | cut -d'"' -f2 || echo "$VERSION")
    UPDATE_AVAILABLE=0
    
    if [[ "$LATEST_VERSION" != "$VERSION" ]]; then
        HIGHEST_VERSION=$(printf '%s\n%s' "$VERSION" "$LATEST_VERSION" | sort -V | tail -n1)
        if [[ "$HIGHEST_VERSION" == "$LATEST_VERSION" ]]; then
            UPDATE_AVAILABLE=1
        fi
    fi
}

run_update() {
    read -p "   Доступна версия $LATEST_VERSION. Обновляемся, или дальше на старье пердеть будем? (y/n): " confirm_update
    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then
        echo -e "${C_YELLOW}🤷‍♂️ Ну и сиди со старьём. Твоё дело.${C_RESET}"; wait_for_enter
        return
    fi

    echo -e "${C_CYAN}🔄 Качаю свежак...${C_RESET}"
    local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    if ! wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL"; then
        echo -e "${C_RED}❌ Хуйня какая-то. Не могу скачать обнову. Проверь инет.${C_RESET}"; rm -f "$TEMP_SCRIPT"; wait_for_enter
        return
    fi

    if ! grep -q 'readonly VERSION' "$TEMP_SCRIPT"; then
        echo -e "${C_RED}❌ Скачалось какое-то дерьмо, а не скрипт. Отбой.${C_RESET}"; rm -f "$TEMP_SCRIPT"; wait_for_enter
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


# --- ОСНОВНЫЕ МОДУЛИ СКРИПТА ---
apply_bbr() { 
    log "🚀 ЗАПУСК ТУРБОНАДДУВА (BBR/CAKE)..."
    local net_status; net_status=$(get_net_status)
    local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1)
    local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2)
    echo "--- ДИАГНОСТИКА ТВОЕГО ДВИГАТЕЛЯ ---"; echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"; echo "------------------------------------"
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && ("$current_qdisc" == "cake" || "$current_qdisc" == "fq") ]]; then
        echo -e "${C_GREEN}✅ Ты уже на форсаже. Не мешай машине работать.${C_RESET}"; log "Проверка «Форсаж»: ОК."; return; fi
    echo "Хм, ездишь на стоке. Пора залить ракетное топливо."
    local available_cc; available_cc=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}')
    local preferred_cc="bbr"; if [[ "$available_cc" == *"bbr2"* ]]; then preferred_cc="bbr2"; fi
    local preferred_qdisc="fq"
    if modprobe sch_cake &>/dev/null; then preferred_qdisc="cake"; else log "⚠️ 'cake' не найден, ставлю 'fq'."; modprobe sch_fq &>/dev/null; fi
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

# --- IPv6 МОДУЛЬ ---
check_ipv6_status() {
    if [ ! -d "/proc/sys/net/ipv6" ]; then
        echo -e "Статус IPv6: ${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"
    elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then
        echo -e "Статус IPv6: ${C_RED}КАСТРИРОВАН${C_RESET}"
    else
        echo -e "Статус IPv6: ${C_GREEN}ВКЛЮЧЁН${C_RESET}"
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
        clear; echo "--- УПРАВЛЕНИЕ IPv6 ---"; check_ipv6_status; echo "--------------------------"; echo "   1. Кастрировать (Отключить)"; echo "   2. Реанимировать (Включить)"; echo "   b. Назад в главное меню"; read -r -p "Твой выбор: " choice
        case $choice in 1) disable_ipv6; wait_for_enter;; 2) enable_ipv6; wait_for_enter;; [bB]) break;; *) echo "1, 2 или 'b'. Не тупи."; sleep 2;; esac
    done
}

# --- МОДУЛЬ ЛОГОВ ---
view_docker_logs() {
    local service_path="$1"; local service_name="$2"
    if [ -z "$service_path" ] || [ ! -d "$service_path" ] || [ ! -f "$service_path/docker-compose.yml" ]; then
        echo -e "❌ ${C_RED}Путь — хуйня, или там нет docker-compose.yml.${C_RESET}";
        return;
    fi
    echo "[*] Показываю потроха '$service_name' из [$service_path]...";
    echo "    (Нажми CTRL+C, чтобы свалить обратно)"
    (cd "$service_path" && sudo docker compose logs -f) || true
    echo -e "\n${C_GREEN}✅ Просмотр логов завершён.${C_RESET}"
    sleep 1
}

# --- НОВАЯ ФУНКЦИЯ ДЛЯ ЛОГА ФОРСАЖА ---
view_forsazh_log() {
    if [ ! -f "$LOGFILE" ]; then
        echo "❌ Лог девственно чист. Ты ещё ничего не натворил.";
        return;
    fi
    echo "[*] Показываю журнал «Форсажа» в реальном времени...";
    echo "    (Нажми CTRL+C, чтобы свалить обратно)"
    # Команда || true глотает ошибку выхода по Ctrl+C
    (sudo tail -f -n 50 "$LOGFILE" | awk -F ' - ' -v C_YELLOW="$C_YELLOW" -v C_RESET="$C_RESET" '{print C_YELLOW $1 C_RESET "  " $2}') || true
    echo -e "\n${C_GREEN}✅ Просмотр журнала завершён.${C_RESET}"
    sleep 1
}

manage_log_path() {
    local service_key="$1"; local service_name_dc="$2"; local service_human_name="$3"; local default_path_opt="$4"; local default_path_root="$5"
    while true; do
        clear; local current_path; current_path=$(load_path "$service_key")
        echo "--- ЛОГИ: $service_human_name ---";
        if [ -n "$current_path" ]; then
            echo "Путь: $current_path"; echo "--------------------------"; echo "   1. Посмотреть"; echo "   2. Стереть путь (указать заново)"; echo "   b. Назад"; read -r -p "Что делаем?: " choice
            case $choice in 1) view_docker_logs "$current_path" "$service_name_dc";; 2) save_path "$service_key" ""; echo "✅ Путь стёрт."; sleep 1;; [bB]) break;; *) echo "1, 2 или 'b'. Других кнопок нет."; sleep 2;; esac
        else
            echo "Путь не указан. Где искать это говно?"; echo "--------------------------"; echo "   1. Стандартный путь ($default_path_opt)"; echo "   2. В папке рута ($default_path_root)"; echo "   3. Указать свой путь"; echo "   b. Назад"; read -r -p "Твой выбор: " choice
            case $choice in 1) save_path "$service_key" "$default_path_opt";; 2) save_path "$service_key" "$default_path_root";; 3) read -r -p "Введи полный путь, гений: " custom_path; save_path "$service_key" "$custom_path";; [bB]) break;; *) echo "Цифру, блядь, нажми."; sleep 2;; esac
        fi
    done
}
security_placeholder() {
    clear
    echo -e "${C_RED}Ты читать умеешь, или только картинки смотришь?${C_RESET}"
    echo ""
    echo -e "Написано же, блядь — ${C_YELLOW}В РАЗРАБОТКЕ${C_RESET}."
    echo "Не лезь, пока не позовут. Сломаешь."
}

# --- ИНФО-ПАНЕЛЬ ВЕРХНЕГО УРОВНЯ ---
display_header() {
    ip_addr=$(hostname -I | awk '{print $1}')
    local net_status; net_status=$(get_net_status)
    local cc; cc=$(echo "$net_status" | cut -d'|' -f1)
    local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2)
    if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then local cc_status="${C_GREEN}АКТИВЕН ($cc + $qdisc)${C_RESET}"; else local cc_status="${C_YELLOW}СТОК ($cc)${C_RESET}"; fi
    local ipv6_status; ipv6_status=$(check_ipv6_status)
    clear
    echo -e "${C_CYAN}--- ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ---${C_RESET}"
    check_for_updates
    if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
        echo -e "${C_YELLOW}🔥 ДОСТУПНО ОБНОВЛЕНИЕ (версия $LATEST_VERSION)${C_RESET}"
    fi
    echo "------------------------------------------------------"
    echo -e "IP Сервера:   ${C_YELLOW}$ip_addr${C_RESET}"
    echo -e "Статус BBR:   $cc_status"
    echo -e "$ipv6_status"
    echo "------------------------------------------------------"
    echo "Чё делать будем, босс?"
    echo ""
}

# --- ГЛАВНОЕ МЕНЮ ---
show_menu() {
    while true; do
        display_header
        echo "   [1] Управление «Форсажем» (BBR+CAKE)"
        echo "   [2] Управление IPv6"
        echo "   [3] Посмотреть журнал «Форсажа»"
        echo "   [4] Посмотреть логи Бота 🤖"
        echo "   [5] Посмотреть логи Панели 📊"
        echo -e "   [6] Безопасность сервера ${C_YELLOW}(В разработке 🚧)${C_RESET}"
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then
            echo -e "   [u] ${C_YELLOW}ОБНОВИТЬ РЕШАЛУ${C_RESET}"
        fi
        echo ""
        echo "   [q] Свалить нахуй (Выход)"
        echo "------------------------------------------------------"
        read -r -p "Твой выбор, босс: " choice
        case $choice in
            1) apply_bbr; wait_for_enter;;
            2) ipv6_menu;;
            3) view_forsazh_log;;
            4) manage_log_path "BOT_LOG_PATH" "remnawave_bot" "Бота" "/opt/remnawave-bedolaga-telegram-bot" "$HOME/remnawave-bedolaga-telegram-bot";;
            5) manage_log_path "PANEL_LOG_PATH" "remnawave" "Панели" "/opt/remnawave" "$HOME/remnawave";;
            6) security_placeholder; wait_for_enter;;
            [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой? Нет такой кнопки."; sleep 2; fi;;
            [qQ]) echo "Был рад помочь. Не обосрись. 🥃"; break;;
            *) echo "Ты прикалываешься? Нет такой кнопки."; sleep 2;;
        esac
    done
}

# --- ГЛАВНЫЙ МОЗГ ---
if [[ "${1:-}" == "install" ]]; then
    install_script "${2:-}"
else
    if [[ $EUID -ne 0 ]]; then 
        if [ "$0" != "$INSTALL_PATH" ]; then
             echo -e "${C_RED}❌ Запускать нужно установленный скрипт с 'sudo'.${C_RESET} Используй: ${C_YELLOW}sudo ./$0 install${C_RESET}";
        else
             echo -e "${C_RED}❌ Только для рута. Используй: ${C_YELLOW}sudo reshala${C_RESET}";
        fi
        exit 1;
    fi
    show_menu
fi
