#!/bin/bash
# ============================================================ #
# ==        Установщик фреймворка «Решала» v1.0             == #
# ============================================================ #
#
# Этот скрипт — просто "загрузчик". Его единственная задача —
# скачать последнюю версию фреймворка и запустить его
# собственный установщик.
#
set -e

# --- Настройки (можно вынести, но для простоты оставим здесь) ---
REPO_OWNER="DonMatteoVPN"
REPO_NAME="reshala-script"
REPO_BRANCH="dev" # <-- ВАЖНО: Укажи правильную ветку!

# --- Цвета ---
C_RESET='\033[0m'; C_CYAN='\033[0;36m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m';

# --- Проверка на root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${C_RED}[✗] Этот установщик должен быть запущен от имени root или через sudo.${C_RESET}"
    exit 1
fi

echo -e "${C_CYAN}[i] Запускаю загрузчик Решалы...${C_RESET}"

# --- Скачивание архива ---
REPO_ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
TEMP_DIR=$(mktemp -d /tmp/reshala_bootstrap.XXXXXX)

echo -e "${C_CYAN}[i] Скачиваю последнюю версию из ветки '${REPO_BRANCH}'...${C_RESET}"
if ! curl -sL --fail -o "${TEMP_DIR}/reshala.tar.gz" "$REPO_ARCHIVE_URL"; then
    echo -e "${C_RED}[✗] Не удалось скачать архив. Проверь интернет или доступность репозитория.${C_RESET}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# --- Распаковка ---
echo -e "${C_CYAN}[i] Распаковываю файлы...${C_RESET}"
if ! tar -xzf "${TEMP_DIR}/reshala.tar.gz" -C "$TEMP_DIR" --strip-components=1; then
    echo -e "${C_RED}[✗] Не удалось распаковать архив.${C_RESET}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# --- Запуск внутреннего установщика ---
INSTALL_SCRIPT="${TEMP_DIR}/reshala.sh"
if [ -f "$INSTALL_SCRIPT" ]; then
    echo -e "${C_GREEN}[✓] Файлы готовы. Передаю управление основному установщику...${C_RESET}"
    echo "------------------------------------------------------"
    # Запускаем основной скрипт с аргументом 'install'
    bash "$INSTALL_SCRIPT" install
else
    echo -e "${C_RED}[✗] Критическая ошибка: главный файл reshala.sh не найден в архиве!${C_RESET}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# --- Очистка ---
rm -rf "$TEMP_DIR"