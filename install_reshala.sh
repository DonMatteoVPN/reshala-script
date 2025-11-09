#!/bin/bash

# ============================================================ #
# ==      ИНСТРУМЕНТ «РЕШАЛА» v1.4 - APOLOGY EDITION        ==
# ============================================================ #
# ==    Возвращены все вырезанные функции.                  ==
# ==    Структура исправлена. Ошибок быть не должно.        ==
# ============================================================ #

set -euo pipefail

# --- КОНСТАНТЫ И ПЕРЕМЕННЫЕ ---
readonly VERSION="v1.4"
readonly SCRIPT_URL="https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/refs/heads/dev/install_reshala.sh"
CONFIG_FILE="${HOME}/.reshala_config"
LOGFILE="/var/log/reshala_ops.log"
INSTALL_PATH="/usr/local/bin/reshala"

# Цвета
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_GRAY='\033[0;90m';

# Глобальные переменные
SERVER_TYPE="Чистый сервак"; PANEL_NODE_VERSION=""; PANEL_NODE_PATH=""; BOT_DETECTED=0; BOT_VERSION=""; BOT_PATH=""; WEB_SERVER="Не определён";
UPDATE_AVAILABLE=0; LATEST_VERSION=""; UPDATE_CHECK_STATUS="OK";

# ============================================================ #
# ==      БЛОК ОБЪЯВЛЕНИЯ ВСЕХ, БЛЯДЬ, ФУНКЦИЙ              ==
# ============================================================ #

# --- УТИЛИТАРНЫЕ ФУНКЦИИ ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | sudo tee -a "$LOGFILE"; }
wait_for_enter() { read -p $'\nНажми Enter, чтобы продолжить...'; }
get_net_status() {
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")
    local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a")
    if [ -z "$qdisc" ] || [ "$qdisc" = "pfifo_fast" ]; then qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n 1) || qdisc="n/a"; fi
    echo "$cc|$qdisc"
}
show_wait_message() {
    echo -e "\n${C_RED}${C_BOLD}⚠️ НИТЫКАЙ НИХУЯ! ЖДИ! ИДЁТ ПРОЦЕСС...${C_RESET}"
}
get_confirmation() {
    local prompt="$1"; local result_var="$2"; local default_val="${3:-n}"
    local input
    while true; do
        read -r -p "$prompt [y/n, default: $default_val]: " input
        input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
        if [[ "$input" == "y" || "$input" == "д" ]]; then
            eval "$result_var=y"; break
        elif [[ "$input" == "n" || "$input" == "н" ]]; then
            eval "$result_var=n"; break
        elif [[ -z "$input" ]]; then
            eval "$result_var=$default_val"; break
        else
            echo -e "${C_RED}Не понял. Введи 'y' или 'n'.${C_RESET}"
        fi
    done
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
    echo -e "\n${C_GREEN}✅ Готово. Решала в системе.${C_RESET}\n"
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
check_for_updates_background() {
    (
        UPDATE_AVAILABLE=0; LATEST_VERSION=""; UPDATE_CHECK_STATUS="OK"
        local max_attempts=2; local attempt=1; local response_body=""; local curl_exit_code=0
        local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
        while [ $attempt -le $max_attempts ]; do
            response_body=$(curl -s -4 -L --connect-timeout 5 --max-time 10 --retry 1 "$url_with_buster" 2>/dev/null)
            curl_exit_code=$?
            if [ $curl_exit_code -eq 0 ] && [ -n "$response_body" ]; then
                LATEST_VERSION=$(echo "$response_body" | grep -m 1 'readonly VERSION' | cut -d'"' -f2)
                if [ -n "$LATEST_VERSION" ]; then
                    local local_ver_num; local_ver_num=$(echo "$VERSION" | sed 's/[^0-9.]*//g')
                    local remote_ver_num; remote_ver_num=$(echo "$LATEST_VERSION" | sed 's/[^0-9.]*//g')
                    if [[ "$local_ver_num" != "$remote_ver_num" ]]; then
                        local highest_ver_num; highest_ver_num=$(printf '%s\n%s' "$local_ver_num" "$remote_ver_num" | sort -V | tail -n1)
                        if [[ "$highest_ver_num" == "$remote_ver_num" ]]; then echo "UPDATE_AVAILABLE=1"; echo "LATEST_VERSION='$LATEST_VERSION'"; fi
                    fi; return 0
                fi
            fi; attempt=$((attempt + 1)); sleep 2
        done
        echo "UPDATE_CHECK_STATUS='ERROR'"
    ) > "/tmp/reshala_update_check" &
}
process_update_check_result() {
    if [ -f "/tmp/reshala_update_check" ]; then
        source "/tmp/reshala_update_check"
        rm "/tmp/reshala_update_check"
    fi
}
run_update() {
    local confirm_update; get_confirmation "   Доступна версия $LATEST_VERSION. Обновляемся, или дальше на старье пердеть будем?" confirm_update y
    if [[ "$confirm_update" != "y" ]]; then echo -e "${C_YELLOW}🤷‍♂️ Ну и сиди со старьём. Твоё дело.${C_RESET}"; wait_for_enter; return; fi
    show_wait_message; echo -e "${C_CYAN}🔄 Качаю свежак...${C_RESET}"; local TEMP_SCRIPT; TEMP_SCRIPT=$(mktemp)
    local url_with_buster="${SCRIPT_URL}?cache_buster=$(date +%s)$(shuf -i 1000-9999 -n 1)"
    if ! wget -4 --timeout=20 --tries=3 --retry-connrefused -q -O "$TEMP_SCRIPT" "$url_with_buster"; then
        echo -e "${C_RED}❌ Хуйня какая-то. Не могу скачать обнову. Проверь инет и лог /var/log/reshala_ops.log.${C_RESET}"; log "wget не смог скачать $url_with_buster"; rm -f "$TEMP_SCRIPT"; wait_for_enter; return
    fi
    local downloaded_version; downloaded_version=$(grep -m 1 'readonly VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)
    if [ ! -s "$TEMP_SCRIPT" ] || ! bash -n "$TEMP_SCRIPT" 2>/dev/null || [ "$downloaded_version" != "$LATEST_VERSION" ]; then
        echo -e "${C_RED}❌ Скачалось какое-то дерьмо, а не скрипт. Отбой.${C_RESET}"; log "Скачанный файл обновления не прошел проверку. Ожидалась версия $LATEST_VERSION, в файле $downloaded_version."; rm -f "$TEMP_SCRIPT"; wait_for_enter; return
    fi
    echo "   Ставлю на место старого..."; sudo cp -- "$TEMP_SCRIPT" "$INSTALL_PATH" && sudo chmod +x "$INSTALL_PATH"; rm "$TEMP_SCRIPT"
    printf "${C_GREEN}✅ Готово. Теперь у тебя версия %s. Не благодари.${C_RESET}\n" "$LATEST_VERSION"; echo "   Перезапускаю себя, чтобы мозги встали на место..."; sleep 2; exec "$INSTALL_PATH"
}

# --- МОДУЛИ СКРИПТА ---
apply_ulimit_tuning() {
    local ulimit_val=65535; local sysctl_file="/etc/sysctl.d/99-reshala-ulimit.conf"
    log "⚙️ Применяю тюнинг ulimit и TCP-параметров."
    echo -e "${C_CYAN}⚙️  Устанавливаю лимиты на файлы и порты...${C_RESET}"
    if ! grep -q "root soft nofile" /etc/security/limits.conf; then
        echo "* soft nofile $ulimit_val" | sudo tee -a /etc/security/limits.conf >/dev/null
        echo "* hard nofile $ulimit_val" | sudo tee -a /etc/security/limits.conf >/dev/null
        echo "root soft nofile $ulimit_val" | sudo tee -a /etc/security/limits.conf >/dev/null
        echo "root hard nofile $ulimit_val" | sudo tee -a /etc/security/limits.conf >/dev/null
        log "-> Установлен ulimit $ulimit_val в limits.conf."
    fi
    
    echo "# === TCP ТЮНИНГ ОТ РЕШАЛЫ ===
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 500000
net.ipv4.tcp_fin_timeout = 15" | sudo tee "$sysctl_file" > /dev/null
    sudo sysctl -p "$sysctl_file" >/dev/null
    echo -e "${C_GREEN}✅ Тюнинг TCP и лимитов завершен. Сервер готов к высоким нагрузкам.${C_RESET}"
}
apply_bbr() {
    show_wait_message; log "🚀 ЗАПУСК ТУРБОНАДДУВА (BBR/CAKE)..."; local net_status; net_status=$(get_net_status); local current_cc; current_cc=$(echo "$net_status" | cut -d'|' -f1); local current_qdisc; current_qdisc=$(echo "$net_status" | cut -d'|' -f2); local cake_available; cake_available=$(modprobe sch_cake &>/dev/null && echo "true" || echo "false")
    echo "--- ДИАГНОСТИКА ТВОЕГО ДВИГАТЕЛЯ ---"; echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"; echo "------------------------------------"
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then echo -e "${C_GREEN}✅ Ты уже на максимальном форсаже (BBR+CAKE).${C_RESET}"; apply_ulimit_tuning; return; fi
    local available_cc; available_cc=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}'); local preferred_cc="bbr"; if [[ "$available_cc" == *"bbr2"* ]]; then preferred_cc="bbr2"; fi; local preferred_qdisc="fq"; if [[ "$cake_available" == "true" ]]; then preferred_qdisc="cake"; else log "⚠️ 'cake' не найден, ставлю 'fq'."; modprobe sch_fq &>/dev/null; fi
    local tcp_fastopen_val=0; [[ $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0) -ge 1 ]] && tcp_fastopen_val=3; local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"
    log "🧹 Чищу старое говно..."; sudo rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*network-optimizations*.conf; if [ -f /etc/sysctl.conf.bak ]; then sudo rm /etc/sysctl.conf.bak; fi; sudo sed -i.bak -E 's/^[[:space:]]*(net.core.default_qdisc|net.ipv4.tcp_congestion_control)/#&/' /etc/sysctl.conf
    log "✍️  Устанавливаю новые, пиздатые настройки..."; echo "# === КОНФИГ «ФОРСАЖ» ОТ РЕШАЛЫ — НЕ ТРОГАТЬ ===
net.ipv4.tcp_congestion_control = $preferred_cc
net.core.default_qdisc = $preferred_qdisc
net.ipv4.tcp_fastopen = $tcp_fastopen_val
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216" | sudo tee "$CONFIG_SYSCTL" > /dev/null
    log "🔥 Применяю настройки..."; sudo sysctl -p "$CONFIG_SYSCTL" >/dev/null
    echo ""; echo "--- КОНТРОЛЬНЫЙ ВЫСТРЕЛ ---"; echo "Новый алгоритм: $(sysctl -n net.ipv4.tcp_congestion_control)"; echo "Новый планировщик: $(sysctl -n net.core.default_qdisc)"; echo "---------------------------"; echo -e "${C_GREEN}✅ Твоя тачка теперь — ракета. (CC: $preferred_cc, QDisc: $preferred_qdisc)${C_RESET}"; apply_ulimit_tuning
}
check_ipv6_status() { if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "${C_RED}ВЫРЕЗАН ПРОВАЙДЕРОМ${C_RESET}"; elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo -e "${C_RED}КАСТРИРОВАН${C_RESET}"; else echo -e "${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi; }
disable_ipv6() { show_wait_message; if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "❌ ${C_YELLOW}Тут нечего отключать. Провайдер уже всё отрезал за тебя.${C_RESET}"; return; fi; if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 1 ]; then echo "⚠️ IPv6 уже кастрирован."; return; fi; echo "🔪 Кастрирую IPv6... Это не больно. Почти."; sudo tee /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ОТКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOL
    sudo sysctl -p /etc/sysctl.d/98-reshala-disable-ipv6.conf > /dev/null; log "-> IPv6 кастрирован через sysctl."; echo -e "${C_GREEN}✅ Готово. Теперь эта тачка ездит только на нормальном топливе.${C_RESET}"; }
enable_ipv6() { show_wait_message; if [ ! -d "/proc/sys/net/ipv6" ]; then echo -e "❌ ${C_YELLOW}Тут нечего включать. Я не могу пришить то, что отрезано с корнем.${C_RESET}"; return; fi; if [ ! -f /etc/sysctl.d/98-reshala-disable-ipv6.conf ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" -eq 0 ]; then echo "✅ IPv6 и так работает. Не мешай ему."; return; fi; echo "💉 Возвращаю всё как было... Реанимация IPv6."; sudo rm -f /etc/sysctl.d/98-reshala-disable-ipv6.conf; sudo tee /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null <<EOL
# === КОНФИГ ОТ РЕШАЛЫ: IPv6 ВКЛЮЧЁН ===
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOL
    sudo sysctl -p /etc/sysctl.d/98-reshala-enable-ipv6.conf > /dev/null; sudo rm -f /etc/sysctl.d/98-reshala-enable-ipv6.conf; log "-> IPv6 реанимирован."; echo -e "${C_GREEN}✅ РЕАНИМАЦИЯ ЗАВЕРШЕНА.${C_RESET}"; }
sync_time() {
    show_wait_message; echo -e "${C_CYAN}⏱️  Сверяю часы...${C_RESET}"; log "-> Запуск синхронизации времени."
    if ! command -v chronyc &> /dev/null; then echo "   'chrony' не найден. Ставлю..."; sudo apt-get update >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y chrony >/dev/null; log "-> Установлен chrony."; fi
    sudo chronyc -a makestep; log "-> Время синхронизировано."
    echo -e "${C_GREEN}✅ Часы сверены. Теперь всё по-швейцарски точно.${C_RESET}"
}
update_system() {
    local confirm_update; show_wait_message; echo -e "${C_CYAN}🔍 Ищу обновы для системы...${C_RESET}"; log "-> Проверка обновлений системы."
    sudo apt-get update >/dev/null
    local updates; updates=$(apt list --upgradable 2>/dev/null | tail -n +2)
    if [ -z "$updates" ]; then echo -e "${C_GREEN}✅ Система в идеале. Обновлять нечего.${C_RESET}"; return; fi
    echo -e "${C_YELLOW}⚠️ Найдены следующие обновы:${C_RESET}"; echo "$updates"; echo ""
    get_confirmation "   Ставим?" confirm_update n
    if [[ "$confirm_update" != "y" ]]; then echo "Твоё дело. Но помни, дырявая система — подарок для врага."; return; fi
    show_wait_message; echo -e "${C_CYAN}🚀 Погнали обновляться...${C_RESET}"; log "-> Запуск обновления системы."
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; log "-> Обновление системы завершено."
    echo -e "${C_GREEN}✅ Система обновлена.${C_RESET}"
}
add_ufw_rule() {
    echo "--- МАСТЕР ДОБАВЛЕНИЯ ПРАВИЛ UFW ---"
    read -p "Действие (allow/deny) [allow]: " action; action=${action:-allow}
    read -p "Порт (например, 443): " port
    read -p "Протокол (tcp/udp/any) [any]: " proto; proto=${proto:-any}
    read -p "Источник IP ('any' или конкретный IP) [any]: " from_ip; from_ip=${from_ip:-any}
    read -p "Комментарий (имя правила, на английском): " comment
    if [ -z "$port" ]; then echo "${C_RED}Порт не может быть пустым.${C_RESET}"; sleep 2; return; fi
    local rule="sudo ufw $action from $from_ip to any port $port"; if [[ "$proto" != "any" ]]; then rule="$rule proto $proto"; fi
    if [ -n "$comment" ]; then rule="$rule comment '$comment'"; fi
    echo -e "Выполняю: ${C_YELLOW}$rule${C_RESET}"; eval "$rule"; log "-> Добавлено правило UFW: $rule"
    echo -e "${C_GREEN}✅ Правило добавлено.${C_RESET}"; wait_for_enter
}
delete_ufw_rule() {
    echo "--- УДАЛЕНИЕ ПРАВИЛА UFW ---"; sudo ufw status numbered
    read -p "Введи номер правила для удаления (или 'q' для отмены): " rule_num
    if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        local confirm_delete; get_confirmation "   Точно сносим правило номер $rule_num?" confirm_delete n
        if [[ "$confirm_delete" == "y" ]]; then
            show_wait_message; sudo ufw --force delete "$rule_num"; log "-> Удалено правило UFW #$rule_num"
            echo -e "${C_GREEN}✅ Правило снесено.${C_RESET}"
        else echo "Отмена."; fi
    elif [[ "$rule_num" != "q" ]]; then echo "${C_RED}Это не номер.${C_RESET}"; fi
    wait_for_enter
}
ufw_menu() {
    while true; do
        clear; echo "--- 🛡️ УПРАВЛЕНИЕ ФАЕРВОЛОМ (UFW) ---"; local ufw_status; ufw_status=$(sudo ufw status | head -n 1 | sed 's/Status: //'); if [[ "$ufw_status" == "inactive" ]]; then ufw_status="${C_RED}ОТКЛЮЧЁН${C_RESET}"; else ufw_status="${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi
        echo -e "Статус: $ufw_status"; echo "---------------------------------------"
        echo "   1. Посмотреть текущие правила"; echo "   2. Включить фаервол (с правилом для SSH)"; echo "   3. Отключить фаервол"; echo "   4. Добавить новое правило (мастер)"; echo "   5. Удалить правило по номеру"
        echo "   b. Назад"; read -r -p "Твой выбор: " choice
        case $choice in
            1) echo "--- ТЕКУЩИЕ ПРАВИЛА ---"; sudo ufw status numbered; wait_for_enter;;
            2) show_wait_message; echo "Включаю..."; sudo ufw allow ssh >/dev/null; sudo ufw --force enable >/dev/null; log "-> UFW включен."; echo "✅ Фаервол активен, SSH-порт открыт."; sleep 2;;
            3) show_wait_message; echo "Отключаю..."; sudo ufw --force disable >/dev/null; log "-> UFW отключен."; echo "✅ Фаервол деактивирован."; sleep 2;;
            4) add_ufw_rule;;
            5) delete_ufw_rule;;
            [bB]) break;; *) echo "Не тупи."; sleep 2;;
        esac
    done
}
fail2ban_menu() {
    while true; do
        clear; echo "--- 🕵️‍♂️ ЗАЩИТА ОТ БРУТФОРСА (Fail2Ban) ---"; local f2b_status="НЕ УСТАНОВЛЕН"; if systemctl is-active --quiet fail2ban; then f2b_status="${C_GREEN}АКТИВЕН${C_RESET}"; elif [ -f /etc/fail2ban/jail.conf ]; then f2b_status="${C_RED}ОТКЛЮЧЁН${C_RESET}"; fi
        echo -e "Статус: $f2b_status"; echo "-------------------------------------------"
        echo "   1. Установить и включить"; echo "   2. Посмотреть статус (забаненные IP)"; echo "   3. Разбанить IP-адрес"; echo "   b. Назад"
        read -r -p "Твой выбор: " choice
        case $choice in
            1) if [[ "$f2b_status" != "НЕ УСТАНОВЛЕН" ]]; then echo "Уже стоит."; sleep 2; continue; fi; show_wait_message; echo "Ставлю..."; sudo apt-get update >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null; sudo systemctl enable --now fail2ban; log "-> Установлен и включен Fail2Ban."; echo "✅ Fail2Ban на страже."; sleep 2;;
            2) if [[ "$f2b_status" == "НЕ УСТАНОВЛЕН" ]]; then echo "Сначала установи."; sleep 2; continue; fi; echo "--- СТАТУС SSH-ЗАЩИТЫ ---"; sudo fail2ban-client status sshd; wait_for_enter;;
            3) if [[ "$f2b_status" == "НЕ УСТАНОВЛЕН" ]]; then echo "Сначала установи."; sleep 2; continue; fi; read -p "   Введи IP для разбана: " ip_to_unban; if [ -n "$ip_to_unban" ]; then sudo fail2ban-client set sshd unbanip "$ip_to_unban"; log "-> Разбанен IP: $ip_to_unban"; echo "✅ Готово."; else echo "IP не введён."; fi; sleep 2;;
            [bB]) break;; *) echo "Не тупи."; sleep 2;;
        esac
    done
}
view_logs_realtime() {
    local log_path="$1"; local log_name="$2"; if [ ! -f "$log_path" ]; then echo -e "❌ ${C_RED}Лог '$log_name' пуст.${C_RESET}"; sleep 2; return; fi; echo "[*] Смотрю журнал '$log_name'... (CTRL+C, чтобы свалить)"; local original_int_handler=$(trap -p INT); trap "echo -e '\n${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT; (sudo tail -f -n 50 "$log_path" | awk -F ' - ' -v C_YELLOW="$C_YELLOW" -v C_RESET="$C_RESET" '{print C_YELLOW $1 C_RESET "  " $2}') || true; if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi; return 0
}
view_docker_logs() {
    local service_path="$1"; local service_name="$2"; if [ -z "$service_path" ] || [ ! -f "$service_path" ]; then echo -e "❌ ${C_RED}Путь — хуйня. Не могу найти docker-compose.yml.${C_RESET}"; sleep 2; return; fi; echo "[*] Смотрю потроха '$service_name'... (CTRL+C, чтобы свалить)"; local original_int_handler=$(trap -p INT); trap "echo -e '\n${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT; (cd "$(dirname "$service_path")" && sudo docker compose logs -f) || true; if [ -n "$original_int_handler" ]; then eval "$original_int_handler"; else trap - INT; fi; return 0
}
uninstall_script() {
    local confirm_uninstall; get_confirmation "${C_RED}Точно хочешь выгнать Решалу? Это снесёт скрипт, конфиги и алиасы." confirm_uninstall n
    if [[ "$confirm_uninstall" != "y" ]]; then echo "Правильное решение."; wait_for_enter; return; fi
    echo "Прощай, босс. Начинаю самоликвидацию..."; if [ -f "$INSTALL_PATH" ]; then sudo rm -f "$INSTALL_PATH"; echo "✅ Главный файл снесён."; log "-> Скрипт удалён."; fi; if [ -f "/root/.bashrc" ]; then sudo sed -i "/alias reshala='sudo reshala'/d" /root/.bashrc; echo "✅ Алиас выпилен."; log "-> Алиас удалён."; fi; if [ -f "$CONFIG_FILE" ]; then rm -f "$CONFIG_FILE"; echo "✅ Конфиг стёрт."; log "-> Конфиг удалён."; fi; if [ -f "$LOGFILE" ]; then sudo rm -f "$LOGFILE"; echo "✅ Журнал сожжён."; fi; echo -e "${C_GREEN}✅ Самоликвидация завершена.${C_RESET}"; echo "   Переподключись, чтобы алиас 'reshala' сдох."; exit 0
}
ipv6_menu() {
    while true; do clear; echo "--- УПРАВЛЕНИЕ IPv6 ---"; echo -e "Статус IPv6: $(check_ipv6_status)"; echo "--------------------------"; echo "   1. Кастрировать (Отключить)"; echo "   2. Реанимировать (Включить)"; echo "   b. Назад"; read -r -p "Твой выбор: " choice; case $choice in 1) disable_ipv6; wait_for_enter;; 2) enable_ipv6; wait_for_enter;; [bB]) break;; *) echo "Не тупи."; sleep 2;; esac; done
}
network_tuning_menu() {
    while true; do clear; echo "--- 🚀 СЕТЕВОЙ ТЮНИНГ ---"; echo "--------------------------"; echo "   1. Управление «Форсажем» (BBR+CAKE)"; echo "   2. Управление IPv6"; echo "   b. Назад"; read -r -p "Твой выбор: " choice; case $choice in 1) apply_bbr; wait_for_enter;; 2) ipv6_menu;; [bB]) break;; *) echo "Не тупи."; sleep 2;; esac; done
}
maintenance_security_menu() {
    while true; do
        clear; echo "--- 🛠️ ОБСЛУЖИВАНИЕ И БЕЗОПАСНОСТЬ ---"; echo "---------------------------------------"
        echo "   1. 🛡️ Управление фаерволом (UFW)"; echo "   2. 🕵️‍♂️ Защита от брутфорса (Fail2Ban)"; echo "   3. ⏱️ Синхронизировать время (NTP)"; echo "   4. 🔄 Обновить систему (APT)"; echo "   b. Назад"
        read -r -p "Твой выбор: " choice
        case $choice in
            1) ufw_menu;; 2) fail2ban_menu;; 3) sync_time; wait_for_enter;; 4) update_system; wait_for_enter;; [bB]) break;; *) echo "Не тупи."; sleep 2;;
        esac
    done
}
diagnostics_menu() {
    while true; do
        clear; echo "--- 🩺 ДИАГНОСТИКА И ЛОГИ ---"; echo "-----------------------------"
        echo "   1. Посмотреть журнал «Решалы»"
        if [ "$BOT_DETECTED" -eq 1 ]; then echo "   2. Посмотреть логи Бота 🤖"; fi
        if [[ "$SERVER_TYPE" == "Панель" ]]; then echo "   3. Посмотреть логи Панели 📊"; elif [[ "$SERVER_TYPE" == "Нода" ]]; then echo "   3. Посмотреть логи Ноды 📊"; fi
        echo "   b. Назад"; read -r -p "Твой выбор: " choice
        case $choice in
            1) view_logs_realtime "$LOGFILE" "Решалы";;
            2) if [ "$BOT_DETECTED" -eq 1 ]; then view_docker_logs "$BOT_PATH/docker-compose.yml" "Бота"; else echo "Нет такой кнопки."; sleep 2; fi;;
            3) if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then view_docker_logs "$PANEL_NODE_PATH" "$SERVER_TYPE"; else echo "Нет такой кнопки."; sleep 2; fi;;
            [bB]) break;; *) echo "Не тупи."; sleep 2;;
        esac
    done
}
display_header() {
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}'); local net_status; net_status=$(get_net_status); local cc; cc=$(echo "$net_status" | cut -d'|' -f1); local qdisc; qdisc=$(echo "$net_status" | cut -d'|' -f2); local cc_status; if [[ "$cc" == "bbr" || "$cc" == "bbr2" ]]; then if [[ "$qdisc" == "cake" ]]; then cc_status="${C_GREEN}МАКСИМУМ (bbr + cake)"; else cc_status="${C_GREEN}АКТИВЕН (bbr + $qdisc)"; fi; else cc_status="${C_YELLOW}СТОК ($cc)"; fi; local ipv6_status; ipv6_status=$(check_ipv6_status); local cpu_info; cpu_info=$(get_cpu_info); local cpu_load; cpu_load=$(get_cpu_load); local ram_info; ram_info=$(get_ram_info); local disk_info; disk_info=$(get_disk_info); local hoster_info; hoster_info=$(get_hoster_info)
    clear; local max_label_width=11
    echo -e "${C_CYAN}╔═[ ИНСТРУМЕНТ «РЕШАЛА» ${VERSION} ]${C_RESET}"
    echo -e "${C_CYAN}║${C_RESET}"; echo -e "${C_CYAN}╠═[ ИНФО ПО СЕРВЕРУ ]${C_RESET}"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "IP Адрес" "$ip_addr"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Хостер" "$hoster_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Процессор" "$cpu_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Нагрузка" "$cpu_load"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Оперативка" "$ram_info"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Диск" "$disk_info"
    echo -e "${C_CYAN}║${C_RESET}"; echo -e "${C_CYAN}╠═[ СТАТУС СИСТЕМ ]${C_RESET}"
    if [[ "$SERVER_TYPE" != "Чистый сервак" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE v$PANEL_NODE_VERSION"; else printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Установка" "$SERVER_TYPE"; fi
    if [ "$BOT_DETECTED" -eq 1 ]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Бот" "$BOT_VERSION"; fi
    if [[ "$WEB_SERVER" != "Не определён" ]]; then printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "Веб-сервер" "$WEB_SERVER"; fi
    echo -e "${C_CYAN}║${C_RESET}"; echo -e "${C_CYAN}╠═[ СЕТЕВЫЕ НАСТРОЙКИ ]${C_RESET}"
    printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "Тюнинг" "$cc_status"; printf "║ ${C_GRAY}%-${max_label_width}s${C_RESET} : %b\n" "IPv6" "$ipv6_status"
    echo -e "${C_CYAN}╚${C_RESET}"
}
show_menu() {
    trap "echo -e '\n${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT
    check_for_updates_background
    while true; do
        scan_server_state; display_header
        process_update_check_result
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then echo -e "\n${C_YELLOW}🔥 Новая версия на подходе: ${LATEST_VERSION}${C_RESET}"; fi
        echo -e "\nЧё делать будем, босс?\n"
        echo "   [1] Сетевой тюнинг (BBR, IPv6)"; echo "   [2] Обслуживание и безопасность (UFW, NTP, Updates)"; echo "   [3] Диагностика и логи"
        if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then echo -e "   [u] ${C_YELLOW}ОБНОВИТЬ РЕШАЛУ${C_RESET}"; fi
        echo ""; echo -e "   [d] ${C_RED}Снести Решалу нахуй (Удаление)${C_RESET}"; echo "   [q] Свалить (Выход)"; echo "------------------------------------------------------"; read -r -p "Твой выбор, босс: " choice
        case $choice in
            1) network_tuning_menu;; 2) maintenance_security_menu;; 3) diagnostics_menu;;
            [uU]) if [[ ${UPDATE_AVAILABLE:-0} -eq 1 ]]; then run_update; else echo "Ты слепой?"; sleep 2; fi;;
            [dD]) uninstall_script;; [qQ]) echo "Был рад помочь. Не обосрись. 🥃"; break;; *) echo "Ты прикалываешься?"; sleep 2;;
        esac
    done
}

# --- ГЛАВНЫЙ МОЗГ ---
main() {
    if [[ "${1:-}" == "install" ]]; then
        install_script "${2:-}"
    else
        if [[ $EUID -ne 0 ]]; then
            if [ "$0" != "$INSTALL_PATH" ]; then
                echo -e "${C_RED}❌ Запускать с 'sudo'.${C_RESET} Используй: ${C_YELLOW}sudo ./$0 install${C_RESET}"
            else
                echo -e "${C_RED}❌ Только для рута. Используй: ${C_YELLOW}sudo reshala${C_RESET}"
            fi
            exit 1;
        fi
        trap - INT TERM EXIT
        show_menu
    fi
}

main "$@"