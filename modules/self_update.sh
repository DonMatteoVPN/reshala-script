#!/bin/bash
# ============================================================ #
# ==       МОДУЛЬ УСТАНОВКИ, ОБНОВЛЕНИЯ И УДАЛЕНИЯ          == #
# ============================================================ #
#
# Управляет жизненным циклом самого "Решалы".
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

_perform_install_or_update() {
    local mode=${1:-install} # 'install' or 'update'
    
    local REPO_ARCHIVE_URL="${REPO_URL}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    local TEMP_ARCHIVE; TEMP_ARCHIVE=$(mktemp /tmp/reshala_archive.XXXXXX.tar.gz)
    
    printf_info "Качаю последнюю версию с GitHub..."
    if ! curl -sL --fail -o "$TEMP_ARCHIVE" "$REPO_ARCHIVE_URL"; then
        printf_error "Не могу скачать архив. Проверь интернет или настройки в config/reshala.conf"
        rm -f "$TEMP_ARCHIVE"; return 1
    fi

    local TEMP_DIR; TEMP_DIR=$(mktemp -d /tmp/reshala_extracted.XXXXXX)
    if ! tar -xzf "$TEMP_ARCHIVE" -C "$TEMP_DIR" --strip-components=1; then
        printf_error "Не могу распаковать архив. Файл повреждён?"; rm -f "$TEMP_ARCHIVE"; rm -rf "$TEMP_DIR"; return 1
    fi

    local INSTALL_DIR="/opt/reshala"
    printf_info "Разворачиваю файлы в ${INSTALL_DIR}..."
    run_cmd rm -rf "$INSTALL_DIR"
    run_cmd mkdir -p "$INSTALL_DIR"
    run_cmd cp -r "${TEMP_DIR}/." "$INSTALL_DIR/"
    run_cmd chmod +x "${INSTALL_DIR}/reshala.sh"

    run_cmd ln -sf "${INSTALL_DIR}/reshala.sh" "$INSTALL_PATH"
    
    rm -f "$TEMP_ARCHIVE"; rm -rf "$TEMP_DIR"
    return 0
}

install_script() {
    printf_info "Запуск процедуры установки Решалы..."
    if _perform_install_or_update "install"; then
        if ! grep -q "alias reshala='sudo reshala'" /root/.bashrc 2>/dev/null; then
            echo "alias reshala='sudo reshala'" | run_cmd tee -a /root/.bashrc >/dev/null
        fi
        log "Скрипт установлен/переустановлен."
        printf_ok "Готово. Решала в системе."
        printf "   %b: %b\n" "${C_BOLD}Команда запуска" "${C_YELLOW}sudo reshala${C_RESET}"
        printf_warning "ВАЖНО: ПЕРЕПОДКЛЮЧИСЬ к серверу, чтобы команда заработала."
    fi
}

uninstall_script() {
    printf_warning "Точно хочешь выгнать Решалу?"; read -p "(y/n): " confirm
    if [[ "$confirm" != "y" ]]; then echo "Правильное решение."; return; fi
    printf_info "Начинаю самоликвидацию..."; run_cmd rm -f "$INSTALL_PATH"; run_cmd rm -rf "/opt/reshala"
    if [ -f "/root/.bashrc" ]; then run_cmd sed -i "/alias reshala='sudo reshala'/d" /root/.bashrc; fi
    printf_ok "Самоликвидация завершена. Переподключись к серверу."; exit 0
}

check_for_updates() {
    local remote_version_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/reshala.sh?cachebuster=$(date +%s)"
    local remote_ver; remote_ver=$(curl -s -L --connect-timeout 5 "$remote_version_url" | grep 'readonly VERSION=' | cut -d'"' -f2)
    if [[ -n "$remote_ver" && "$remote_ver" != "$VERSION" ]]; then
        UPDATE_AVAILABLE=1; LATEST_VERSION="$remote_ver"
    else
        UPDATE_AVAILABLE=0; LATEST_VERSION=""
    fi
}

run_update() {
    if _perform_install_or_update "update"; then
        log "Скрипт успешно обновлён до версии ${LATEST_VERSION}."
        printf_ok "Готово. Теперь у тебя версия ${LATEST_VERSION}."
        echo "   Перезапускаю себя, чтобы мозги встали на место..."; sleep 2
        exec "$INSTALL_PATH"
    fi
}