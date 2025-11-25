#!/bin/bash
# ============================================================ #
# ==            ОБЩИЙ МОДУЛЬ (ЯЩИК С ИНСТРУМЕНТАМИ)         == #
# ============================================================ #
#
# Здесь лежат общие функции, которые нужны всем остальным модулям.
# Этот файл не запускается напрямую, а подключается (source).
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# --- Цвета для вывода в терминал ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m';
C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m';
C_GRAY='\033[0;90m'; C_WHITE='\033[1;37m';

# Универсальный хедер для меню (один блок вместо трёх printf подряд)
# Пример: menu_header "🔧 СЕРВИСНОЕ ОБСЛУЖИВАНИЕ (КРУТИМ ГАЙКИ)"
menu_header() {
    local title="$1"
    local width=60  # ширина текстовой области внутри рамки

    # Обрезаем слишком длинный заголовок, чтобы не разъезжалась рамка
    if [ "${#title}" -gt "$width" ]; then
        title="${title:0:$width}"
    fi

    printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    printf "%b\n" "${C_CYAN}║ $(printf '%-*s' "$width" "$title")║${C_RESET}"
    printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
}

# ============================================================ #
#                   БАЗОВЫЕ УТИЛИТЫ                            #
# ============================================================ #

# --- Функции для красивого и стандартизированного вывода ---
printf_info() {
    printf "%b%s%b\n" "${C_CYAN}[i] " "$*" "${C_RESET}"
}
printf_ok() {
    printf "%b%s%b\n" "${C_GREEN}[✓] " "$*" "${C_RESET}"
}
printf_warning() {
    printf "%b%s%b\n" "${C_YELLOW}[!] " "$*" "${C_RESET}"
}
printf_error() {
    printf "%b%s%b\n" "${C_RED}[✗] " "$*" "${C_RESET}"
    sleep 2
}

# Короткие алиасы в стиле info/ok/warn/err
info() { printf_info "$@"; }
ok()   { printf_ok "$@"; }
warn() { printf_warning "$@"; }
err()  { printf_error "$@"; }

# Короткие алиасы в стиле info/ok/warn/err, как ты показал в примере
info() { printf_info "$@"; }
ok()   { printf_ok "$@"; }
warn() { printf_warning "$@"; }
err()  { printf_error "$@"; }

# --- Логирование ---
init_logger() {
    if ! [ -f "$LOGFILE" ]; then
        touch "$LOGFILE" &>/dev/null || true
        chmod 666 "$LOGFILE" &>/dev/null || true
    fi
}

log() {
    # Запись в лог через нашу умную run_cmd, чтобы она сама решала, нужен sudo или нет
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $*" | run_cmd tee -a "$LOGFILE" > /dev/null
}

# --- Запуск команд от имени root, если нужно ---
run_cmd() {
    if [[ $EUID -eq 0 ]]; then
        # Если мы уже root, просто выполняем команду
        "$@"
    elif command -v sudo &>/dev/null; then
        # Если мы не root, но sudo есть - используем его
        sudo "$@"
    else
        # Если мы не root и sudo нет - это пиздец.
        printf_error "Команда 'sudo' не найдена. Запусти скрипт от имени root."
        # Тут можно было бы и выйти, но дадим шанс другим частям скрипта среагировать
        return 1
    fi
}

# --- Умный ввод с поддержкой Readline и дефолтных значений ---
safe_read() {
    local prompt="$1"
    local default="${2:-}"
    local result
    read -e -p "$prompt" -i "$default" result
    echo "${result:-$default}"
}

# --- Простое ожидание нажатия Enter ---
wait_for_enter() {
    read -rp $'\nНажми Enter, чтобы продолжить...'
}

# --- Проверка наличия и установка пакетов ---
ensure_package() {
    local package_name="$1"
    if ! command -v "$package_name" &>/dev/null; then
        printf_warning "Утилита '${package_name}' не найдена. Устанавливаю..."
        if command -v apt-get &>/dev/null; then
            run_cmd apt-get update -qq >/dev/null
            run_cmd apt-get install -y -qq "$package_name"
        elif command -v yum &>/dev/null; then
            run_cmd yum install -y "$package_name"
        else
            printf_error "Не могу автоматически установить '${package_name}'. Сделай это вручную."
            return 1
        fi
    fi
    return 0
}

# Записывает или обновляет значение переменной в конфиге
set_config_var() {
    local key="$1"
    local value="$2"
    local config_file="${SCRIPT_DIR}/config/reshala.conf"
    
    # Если ключ уже есть - заменяем. Если нет - добавляем.
    if grep -q "^${key}=" "$config_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$config_file"
    else
        echo "${key}=\"${value}\"" >> "$config_file"
    fi
}

# Читает значение переменной из конфига
get_config_var() {
    local key="$1"
    local config_file="${SCRIPT_DIR}/config/reshala.conf"
    
    if [ -f "$config_file" ]; then
        # Ищем значение, убираем кавычки и возвращаем
        grep "^${key}=" "$config_file" 2>/dev/null | cut -d'=' -f2- | sed 's/"//g'
    fi
}

# ============================================================ #
#                   УТИЛИТЫ ДЛЯ ЛОГОВ                          #
# ============================================================ #
# Вынесены из старого монолита install_reshala.sh

# Реалтайм-просмотр логов (tail -f) с аккуратным trap'ом
view_logs_realtime() {
    local log_path="$1"
    local log_name="$2"

    # Если файла нет, создаём, чтобы tail не ругался
    if [ ! -f "$log_path" ]; then
        run_cmd touch "$log_path"
        run_cmd chmod 666 "$log_path"
    fi

    echo "[*] Смотрю журнал '$log_name'... (CTRL+C, чтобы свалить)"
    printf "%b[+] Лог-файл: %s${C_RESET}\n" "${C_CYAN}" "$log_path"

    local original_int_handler
    original_int_handler=$(trap -p INT)
    trap "printf '\n%b\n' '${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT

    # Просто tail -f, как в старые добрые времена — без лишней магии
    run_cmd tail -f -n 50 "$log_path"

    if [ -n "$original_int_handler" ]; then
        eval "$original_int_handler"
    else
        trap - INT
    fi
    return 0
}

# Просмотр логов docker-compose сервиса по пути к compose-файлу
view_docker_logs() {
    local service_path="$1"
    local service_name="$2"

    if [ -z "$service_path" ] || [ ! -f "$service_path" ]; then
        printf "%b\n" "❌ ${C_RED}Путь к Docker-compose не найден. Возможно, ты что-то удалил руками?${C_RESET}"
        sleep 2
        return
    fi

    echo "[*] Смотрю потроха '$service_name'... (CTRL+C, чтобы свалить)"
    local original_int_handler
    original_int_handler=$(trap -p INT)
    trap "printf '\n%b\n' '${C_GREEN}✅ Возвращаю в меню...${C_RESET}'; sleep 1;" INT

    (
        cd "$(dirname "$service_path")" && run_cmd docker compose logs -f
    ) || true

    if [ -n "$original_int_handler" ]; then
        eval "$original_int_handler"
    else
        trap - INT
    fi
    return 0
}
