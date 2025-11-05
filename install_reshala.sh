#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v0.304 dev - РАБОТА НАД ОШИБКАМИ ==
# ============================================================ #
# ==    Восстановлена база v0.300. Новые фичи интегрированы.   ==
# ============================================================ #

set -euo pipefail

# --- КОНСТАНТЫ И ПЕРЕМЕННЫЕ ---
readonly VERSION="v0.304 dev"
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/dev/install_reshala.sh"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala_ops.log"
INSTALL_PATH="/usr/local/bin/reshala"

# Цвета
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m';

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
    if ! wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL"; then echo -e "${C_RED}❌ Не могу скачать последнюю версию.${C_RESET}"; exit 1; fi
    sudo cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && sudo chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"
    if ! grep -q "alias reshala='sudo reshala'" /root/.bashrc 2>/dev/null; then echo "alias reshala='sudo reshala'" | sudo tee -a /root/.bashrc >/dev/null; fi
    echo -e "\n${C_GREEN}✅ Готово. Решала в системе.${C_RESET}\n"
    if [[ $(id -u) -eq 0 ]]; then echo -e "   ${C_BOLD}Команда:${C_RESET} ${C_YELLOW}reshala${C_RESET}"; else echo -e "   ${C_BOLD}Команда:${C_RESET} ${C_YELLOW}sudo reshala${C_RESET}"; fi
    echo -e "   ${C_RED}⚠️ ВАЖНО: ПЕРЕПОДКЛЮЧИСЬ к серверу.${C_RESET}"
    if [[ "${1:-}" != "update" ]]; then echo -e "   Установочный файл ('$0') можешь сносить."; fi
}

# --- МОДУЛЬ ОБНОВЛЕНИЯ (ИСПРАВЛЕННЫЙ ИЗ v0.300) ---
check_for_updates() {
    UPDATE_AVAILABLE=0
    UPDATE_CHECK_STATUS="OK"
    
    LATEST_VERSION=$(curl -s --connect-timeout 5 "$SCRIPT_URL" | grep -m 1 'readonly VERSION' | cut -d'"' -f2 || true)

    if [ -z "$LATEST_VERSION" ]; then
        UPDATE_CHECK_STATUS="ERROR"
        return
    fi
    
    if [[ "$LATEST_VERSION" != "$VERSION" ]]; then
        local highest_version; highest_version=$(printf '%s\n%s' "$VERSION" "$LATEST_VERSION" | sort -V | tail -n1)
        if [[ "$highest_version" == "$LATEST_VERSION" ]]; then
            UPDATE_AVAILABLE=1
        fi
    fi
}

run_update() {
    read -p "   Доступна версия $LATEST_VERSION. Обновляемся? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo -e "${C_YELLOW}🤷‍♂️ Твоё дело.${C_RESET}"; wait_for_enter; return; fi
    echo -e "${C_CYAN}🔄 Качаю свежак...${C_RESET}"
    local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    if ! wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL"; then echo -e "${C_RED}❌ Не могу скачать обнову.${C_RESET}"; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; fi
    if ! grep -q 'readonly VERSION' "$TEMP_SCRIPT"; then echo -e "${C_RED}❌ Скачалось дерьмо, а не скрипт.${C_RESET}"; rm -f "$TEMP_SCRIPT"; wait_for_enter; return; fi
    echo "   Ставлю на место старого..."
    sudo cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && sudo chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"
    printf "${C_GREEN}✅ Готово. Теперь у тебя версия %s.${C_RESET}\n" "$LATEST_VERSION"
    echo "   Перезапускаю себя..."; sleep 2; exec "$INSTALL_PATH"
}

# --- МОДУЛЬ АВТООПРЕДЕЛЕНИЯ (НОВЫЙ) ---
scan_server_state() {
    SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён"
    local container_name=""
    if sudo docker ps --format '{{.Names}}' | grep -q "^remnawave$"; then
        SERVER_TYPE="Панель"; container_name="remnawave"
    elif sudo docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then
        SERVER_TYPE="Нода"; container_name="remnanode"
    fi

    if [ -n "$container_name" ]; then
        PANEL_NODE_PATH=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container_name" 2>/dev/null)
        local version_label=$(sudo docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$container_name" 2>/dev/null)
        if [ -n "$version_label" ]; then
            PANEL_NODE_VERSION="$version_label"
        else
            local image_tag=$(sudo docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)
            PANEL_NODE_VERSION="tag: $(echo "$image_tag" | cut -d':' -f2)"
        fi
    fi

    local bot_container_name="remnawave_bot"
    if sudo docker ps --format '{{.Names}}' | grep -q "^${bot_container_name}$"; then
        BOT_DETECTED=1
        local bot_compose_path=$(sudo docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$bot_container_name" 2>/dev/null || true)
        if [ -n "$bot_compose_path" ]; then BOT_PATH=$(dirname "$bot_compose_path"); fi
        
        local bot_version_label=$(sudo docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' "$bot_container_name" 2>/dev/null)
        if [ -n "$bot_version_label" ]; then
            BOT_VERSION="$bot_version_label"
        elif [ -f "$BOT_PATH/VERSION" ]; then
            BOT_VERSION=$(cat "$BOT_PATH/VERSION")
        else
            local bot_image_tag=$(sudo docker inspect --format='{{.Config.Image}}' "$bot_container_name" 2>/dev/null)
            BOT_VERSION="tag: $(echo "$bot_image_tag" | cut -d':' -f2)"
        fi
    fi

    if sudo docker ps --format '{{.Names}}' | grep -q "remnawave-nginx"; then
        WEB_SERVER="Nginx (в Docker)"
    elif sudo docker ps --format '{{.Image}}' | grep -q "caddy"; then
        WEB_SERVER="Caddy (в Docker)"
    elif ss -tlpn | grep -q -E 'nginx|caddy|apache2|httpd'; then
        WEB_SERVER=$(ss -tlpn | grep -E 'nginx|caddy|apache2|httpd' | head -n 1 | sed -n 's/.*users:(("\([^"]*\)".*))/\2/p')
    fi
}


# --- ОСНОВНЫЕ МОДУЛИ СКРИПТА ---
apply_bbr() {
    log "🚀 ЗАПУСК ТУРБОНАДДУВА (BBR/CAKE)..."
    local net_status; net_status=$(get_net_status); local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1); local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2)
    local cake_available; cake_available=$(modprobe sch_cake &>/dev/null && echo "true" || echo "false")
    echo "--- ДИАГНОСТИКА ---"; echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"; echo "--------------------"
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then echo -e "${C_GREEN}✅ Ты уже на максималках.${C_RESET}"; log "Проверка «Форсаж»: Максимум."; return; fi
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "fq" && "$cake_available" == "true" ]]; then
        echo -e "${C_YELLOW}⚠️ У тебя неплохо (BBR+FQ), но можно лучше.${C_RESET}"; read -p "   Хочешь апгрейд до CAKE? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "Как скажешь."; return; fi; echo "Красава. Делаем как надо."
    elif [[ "$current_cc" != "bbr" && "$current_cc" != "bbr2" ]]; then echo "Ездишь на стоке. Включаем форсаж."; fi
    local available_cc; available_cc=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}'); local preferred_cc="bbr"; if [[ "$available_cc" == *"bbr2"* ]]; then preferred_cc="bbr2"; fi
    local preferred_qdisc="fq"; if [[ "$cake_available" == "true" ]]; then preferred_qdisc="cake"; else log "⚠️ 'cake' не найден, ставлю 'fq'."; modprobe sch_fq &>/dev/null; fi
    local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"; log "🧹 Чищу старое..."; sudo rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf
    if [ -f /etc/sysctl.conf.bak ]; then sudo rm /etc/sysctl.conf.bak; fi; sudo sed -i.bak -E 's/^[[:space:]]*(net.core.default_qdisc|net.ipv4.tcp_congestion_control)/#&/' /etc/sysctl.conf
    log "✍️  Ставлю новые настройки..."; echo -e "# === КОНФИГ «ФОРСАЖ» ОТ РЕШАЛЫ — НЕ ТРОГАТЬ ===\nnet.ipv4.tcp_congestion_control = $preferred_cc\nnet.core.default_qdisc = $preferred_qdisc\nnet.ipv4.tcp_fastopen = 3" | sudo tee "$CONFIG_SYSCTL" > /dev/null
    log "🔥 Применяю..."; sudo sysctl -p "$CONFIG_SYSCTL" >/dev/null; echo ""; echo "--- КОНТРОЛЬ ---"; echo "Новый алгоритм: $(sysctl -n net.ipv4.tcp_congestion_control)"; echo "Новый планировщик: $(sysctl -n net.core.default_qdisc)"; echo "----------------"
    echo -e "${C_GREEN}✅ Твоя тачка теперь — ракета. (CC: $preferred_cc, QDisc: $preferred_qdisc)${C_RESET}";
}

ipv6_menu() {
    while true; do
        clear; echo "--- УПРАВЛЕНИЕ IPv6 ---"; if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "Статус IPv6: ${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"; elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo -e "Статус IPv6: ${C_RED}КАСТРИРОВАН${C_RESET}"; else echo -e "Статус IPv6: ${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi; echo "--------------------------"; echo "   1. Кастрировать"; echo "   2. Реанимировать"; echo "   b. Назад"; read -r -p "Твой выбор: " choice
        case $choice in 1) if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "❌ ${C_YELLOW}Нечего отключать.${C_RESET}"; elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo "⚠️ Уже кастрирован."; else echo "🔪 Кастрирую IPv6..."; sudo tee /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null <<< "net.ipv6.conf.all.disable_ipv6 = 1"$'\n'"net.ipv6.conf.default.disable_ipv6 = 1"; sudo sysctl -p /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null; log "-> IPv6 кастрирован."; echo -e "${C_GREEN}✅ Готово.${C_RESET}"; fi; wait_for_enter;; 2) if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "❌ ${C_YELLOW}Нечего включать.${C_RESET}"; elif [ ! -f /etc/sysctl.d/98-reshala-disable-ipv6.conf ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 0 ]; then echo "✅ И так работает."; else echo "💉 Реанимация IPv6..."; sudo rm -f /etc/sysctl.d/98-reshala-disable-ipv6.conf; sudo tee /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null <<< "net.ipv6.conf.all.disable_ipv6 = 0"$'\n'"net.ipv6.conf.default.disable_ipv6 = 0"; sudo sysctl -p /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null; sudo rm -f /etc/sysctl.d/98-reshala-enable-ipv6.conf; log "-> IPv6 реанимирован."; echo -e "${C_GREEN}✅ Готово.${C_RESET}"; fi; wait_for_enter;; [bB]) break;; *) echo "Не тупи."; sleep 2;; esac
    done
}

view_logs_realtime() {
    local log_path="$1"; local log_name="$2"; if [ ! -f "$log_path" ]; then echo -e "❌ ${C_RED}Лог '$log_name' пуст.${C_RESET}"; sleep 2; return; fi
    echo "[*] Смотрю журнал '$log_name'... (CTRL+C, чтобы свалить)"; trap "echo -e '\n${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT
    (sudo tail -f -n 50 "$log_path" | awk -F ' - ' -v C_YELLOW="$C_YELLOW" -v C_RESET="$C_RESET" '{print C_YELLOW $1 C_RESET "  " $2}') || true
    trap - INT; return 0
}

view_docker_logs() {
    local service_path="$1"; local service_name="$2"; if [ -z "$service_path" ] || [ ! -f "$service_path" ]; then echo -e "❌ ${C_RED}Путь — хуйня.${C_RESET}"; sleep 2; return; fi
    echo "[*] Смотрю потроха '$service_name'... (CTRL+C, чтобы свалить)"; trap "echo -e '\n${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT
    (cd "$(dirname "$service_path")" && sudo docker compose logs -f) || true
    trap - INT; return 0
}

manage_log_path() {
    local service_key="$1"; local service_name_dc="$2"; local service_human_name="$3"; local default_path_opt="$4"; local default_path_root="$5"
    while true; do
        clear; local current_path; current_path=$(load_path "$service_key")
        echo "--- ЛОГИ: $service_human_name ---";
        if [ -n "$current_path" ]; then
            echo "Путь: $current_path"; echo "--------------------------"; echo "   1. Посмотреть"; echo "   2. Стереть путь (указать заново)"; echo "   b. Назад"; read -r -p "Твой ход: " choice
            case $choice in 1) view_docker_logs "$current_path" "$service_name_dc";; 2) save_path "$service_key" ""; echo "✅ Путь стёрт."; sleep 1;; [bB]) break;; *) echo "1, 2 или 'b'. Других кнопок нет."; sleep 2;; esac
        else
            echo "Путь не указан. Где искать это говно?"; echo "--------------------------"; echo "   1. Стандартный путь ($default_path_opt)"; echo "   2. В папке рута ($default_path_root)"; echo "   3. Указать свой путь"; echo "   b. Назад"; read -r -p "Твой выбор: " choice
            case $choice in 1) save_path "$service_key" "$default_path_opt";; 2) save_path "$service_key" "$default_path_root";; 3) read -r -p "Введи полный путь, гений: " custom_path; save_path "$service_key" "$custom_path";; [bB]) break;; *) echo "Цифру, блядь, нажми."; sleep 2;; esac
        fi
    done
}

security_placeholder() { clear; echo -e "${C_RED}Написано же, блядь — ${C_YELLOW}В РАЗРАБОТКЕ${C_RESET}. Не лезь."; }

uninstall_script() {
    echo -e "${C_RED}Точно хочешь выгнать Решалу?${C_RESET}"; read -p "Это снесёт скрипт, конфиги и алиасы. (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "Правильное решение."; wait_for_enter; return; fi
    echo "Прощай, босс. Начинаю самоликвидацию...";
    if [ -f "$INSTALL_PATH" ]; then sudo rm -f "$INSTALL_PATH"; echo "✅ Главный файл снесён."; log "-> Скрипт удалён."; fi
    if [ -f "/root/.bashrc" ]; then sudo sed -i "/alias reshala='sudo reshala'/d" /root/.bashrc; echo "✅ Алиас выпилен."; log "-> Алиас удалён."; fi
    if [ -f "$CONFIG_FILE" ]; then rm -f "$CONFIG_FILE"; echo "✅ Конфиг стёрт."; log "-> Конфиг удалён."; fi
    if [ -f "$LOGFILE" ]; then sudo rm -f "$LOGFILE"; echo "✅ Журнал сожжён."; fi
    echo -e "${C_GREEN}✅ Самоликвидация завершена.${C_RESET}"; echo "   Переподключись, чтобы алиас 'reshala' сдох."; exit 0
}

# --- ИНФО-ПАНЕЛЬ И ГЛАВНОЕ МЕНЮ ---
display_header() {
    ip_addr=$(hostname -I | awk '{print $1}'); local net_status; net_status=$(get_net_status); local cc; cc=$(echo "$net_status" | cut -d'|' -f1); local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2)
    local cc_status; if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}МАКСИМУМ ($cc + $qdisc)${C_RESET}"; else cc_status="${C_GREEN}АКТИВЕН ($cc + $qdisc)${C_RESET}"; fi; else cc_status="${C_YELLOW}СТОК ($cc)${C_RESET}"; fi
    local ipv6_status; ipv6_status=$(check_ipv6_status); clear
    echo -e "${C_CYAN}--- ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ---${C_RESET}"
    check_for_updates
    if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then echo -e "${C_YELLOW}🔥 Новая версия на подходе: ${LATEST_VERSION}${C_RESET}";
    elif [[ "$UPDATE_CHECK_STATUS" == "ERROR" ]]; then echo -e "${C_RED}⚠️ Не могу проверить обновления. Проблемы со связью.${C_RESET}"; fi
    echo "------------------------------------------------------"
    echo -e "IP Сервера:   ${C_YELLOW}$ip_addr${C_RESET}"
    if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then echo -e "Тип Сервера:  ${C_YELLOW}$SERVER_TYPE v$PANEL_NODE_VERSION${C_RESET}"; else echo -e "Тип Сервера:  ${C_YELLOW}$SERVER_TYPE${C_RESET}"; fi
    if [ "$BOT_DETECTED" -eq 1 ]; then echo -e "Версия Бота:  ${C_CYAN}$BOT_VERSION${C_RESET}"; fi
    if [[ "$WEB_SERVER" != "Не определён" ]]; then echo -e "Веб-сервер:   ${C_CYAN}$WEB_SERVER${C_RESET}"; fi
    echo -e "Статус BBR:   $cc_status"; echo -e "$ipv6_status"
    echo "------------------------------------------------------"; echo "Чё делать будем, босс?"; echo ""
}

show_menu() {
    while true; do
        scan_server_state; display_header
        echo "   [1] Управление «Форсажем» (BBR+CAKE)"; echo "   [2] Управление IPv6"; echo "   [3] Посмотреть журнал «Форсажа»"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo "   [4] Посмотреть логи Бота 🤖"; fi
        if [[ "$SERVER_TYPE" == "Панель" ]]; then echo "   [5] Посмотреть логи Панели 📊"; elif [[ "$SERVER_TYPE" == "Нода" ]]; then echo "   [5] Посмотреть логи Ноды 📊"; fi
        echo -e "   [6] Безопасность сервера ${C_YELLOW}(В разработке 🚧)${C_RESET}"
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then echo -e "   [u] ${C_YELLOW}ОБНОВИТЬ РЕШАЛУ${C_RESET}"; fi
        echo ""; echo -e "   [d] ${C_RED}Снести Решалу нахуй (Удаление)${C_RESET}"; echo "   [q] Свалить (Выход)"
        echo "------------------------------------------------------"
        read -r -p "Твой выбор, босс: " choice
        case $choice in
            1) apply_bbr; wait_for_enter;; 2) ipv6_menu;; 3) view_logs_realtime "$LOGFILE" "Форсажа";;
            4) if [ "$BOT_DETECTED" -eq 1 ]; then manage_log_path "BOT_LOG_PATH" "remnawave_bot" "Бота" "/opt/remnawave-bedolaga-telegram-bot" "$HOME/remnawave-bedolaga-telegram-bot"; else echo "Нет такой кнопки."; sleep 2; fi;;
            5) if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then manage_log_path "PANEL_LOG_PATH" "remnawave" "$SERVER_TYPE" "/opt/remnawave" "$HOME/remnawave"; else echo "Нет такой кнопки."; sleep 2; fi;;
            6) security_placeholder; wait_for_enter;;
            [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой?"; sleep 2; fi;;
            [dD]) uninstall_script;;
            [qQ]) echo "Был рад помочь. Не обосрись. 🥃"; break;;
            *) echo "Ты прикалываешься?"; sleep 2;;
        esac
    done
}

# --- ГЛАВНЫЙ МОЗГ ---
if [[ "${1:-}" == "install" ]]; then
    install_script "${2:-}"
else
    if [[ $EUID -ne 0 ]]; then 
        if [ "$0" != "$INSTALL_PATH" ]; then echo -e "${C_RED}❌ Запускать с 'sudo'.${C_RESET} Используй: ${C_YELLOW}sudo ./$0 install${C_RESET}";
        else echo -e "${C_RED}❌ Только для рута. Используй: ${C_YELLOW}sudo reshala${C_RESET}"; fi
        exit 1;
    fi
    trap - INT TERM EXIT
    show_menu
fi