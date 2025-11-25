#!/bin/bash
# ============================================================ #
# ==             МОДУЛЬ УПРАВЛЕНИЯ ФЛОТОМ (SKYNET)          == #
# ============================================================ #
#
# Это мозг. Он управляет базой данных серверов, генерирует и
# раскидывает SSH-ключи, инициирует удаленные подключения
# и синхронизирует агентов.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# ============================================================ #
#                  УПРАВЛЕНИЕ SSH-КЛЮЧАМИ                      #
# ============================================================ #

# Проверяет/создаёт главный мастер-ключ
_ensure_master_key() {
    local key_path="${HOME}/.ssh/${SKYNET_MASTER_KEY_NAME}"
    if [ ! -f "$key_path" ]; then
        printf_info "🔑 Генерирую МАСТЕР-КЛЮЧ (${SKYNET_MASTER_KEY_NAME})..."
        ssh-keygen -t ed25519 -f "$key_path" -N "" -q
    fi
    echo "$key_path"
}

# Генерирует уникальный ключ для конкретного сервера
_generate_unique_key() {
    local name="$1"
    local safe_name; safe_name=$(echo "$name" | tr -cd '[:alnum:]_-')
    local key_path="${HOME}/.ssh/${SKYNET_UNIQUE_KEY_PREFIX}${safe_name}"
    if [ ! -f "$key_path" ]; then
        printf_info "🔑 Генерирую УНИКАЛЬНЫЙ ключ для '${name}'..."
        ssh-keygen -t ed25519 -f "$key_path" -N "" -q
    fi
    echo "$key_path"
}

# Закидывает ключ на удалённый сервер, с лечением доступа
_deploy_key_to_host() {
    local ip="$1" port="$2" user="$3" key_path="$4"

    # Лечим ошибку "Host key verification failed", если сервер был переустановлен
    ssh-keygen -R "$ip" >/dev/null 2>&1
    ssh-keygen -R "[$ip]:$port" >/dev/null 2>&1

    printf "   👉 %s@%s:%s... " "$user" "$ip" "$port"
    # Сначала пробуем тихо войти по ключу, вдруг доступ уже есть
    if ssh -q -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -i "$key_path" -p "$port" "${user}@${ip}" exit; then
        printf "%b\n" "${C_GREEN}ДОСТУП ЕСТЬ!${C_RESET}"
        return 0
    fi

    printf "\n   %b🔓 Вводи пароль (один раз), чтобы закинуть ключ...${C_RESET}\n" "${C_YELLOW}"
    if ssh-copy-id -o StrictHostKeyChecking=no -i "${key_path}.pub" -p "$port" "${user}@${ip}"; then
        printf "   ✅ %b\n" "${C_GREEN}Ключ установлен!${C_RESET}"
        return 0
    else
        printf "   ❌ %b\n" "${C_RED}Не удалось (неверный пароль или SSH недоступен)${C_RESET}"
        return 1
    fi
}

# Меню для просмотра ключей (портировано из старого монолита)
_show_keys_menu() {
    # Мягкий trap: CTRL+C возвращает в предыдущее меню, а не убивает всё
    local old_trap
    old_trap=$(trap -p INT)
    trap 'echo; printf_error "Отмена. Возвращаюсь назад."; return' INT

    while true; do
        clear
        menu_header "🔑 УПРАВЛЕНИЕ SSH КЛЮЧАМИ"
        echo ""
        echo "   Здесь можно посмотреть Мастер-ключ и уникальные ключи для серверов."
        echo "   Осторожно: просмотр приватного ключа показывает СЕКРЕТНЫЕ данные."
        echo ""
        echo "Доступные ключи:"
        echo "--------------------------------------------------"

        local keys=()
        local i=1

        # 1. Мастер-ключ
        local master_path="${HOME}/.ssh/${SKYNET_MASTER_KEY_NAME}"
        if [ -f "$master_path" ]; then
            keys[$i]="${master_path}|MASTER KEY (Основной)"
            printf "   [%d] %b%-30s%b (Дефолтный)\n" "$i" "${C_GREEN}" "MASTER KEY" "${C_RESET}"
            ((i++))
        fi

        # 2. Уникальные ключи
        for k in "${HOME}/.ssh/${SKYNET_UNIQUE_KEY_PREFIX}"*; do
            if [[ -f "$k" ]] && [[ "$k" != *.pub ]]; then
                local k_name
                k_name=$(basename "$k" | sed "s/${SKYNET_UNIQUE_KEY_PREFIX}//")
                keys[$i]="$k|$k_name"
                printf "   [%d] %b%-30s%b (Для сервера: %s)\n" "$i" "${C_YELLOW}" "UNIQUE KEY" "${C_RESET}" "$k_name"
                ((i++))
            fi
        done

        echo "--------------------------------------------------"
        echo "   [b] 🔙 Назад"
        echo ""

        local choice
        read -r -p "Выбери ключ для просмотра: " choice || continue

        if [[ "$choice" == "b" || "$choice" == "B" ]]; then
            break
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ -n "${keys[$choice]:-}" ]; then
            IFS='|' read -r k_path k_desc <<< "${keys[$choice]}"

            echo ""
            echo "Что показать?"
            echo "   1) 🔓 ПУБЛИЧНЫЙ (Public)  -> Чтобы закинуть на сервер"
            echo "   2) 🔐 ПРИВАТНЫЙ (Private) -> Чтобы скопировать себе на ПК/Телефон"
            local type_choice; type_choice=$(safe_read "Выбор: " "1")

            if [[ "$type_choice" == "1" ]]; then
                echo ""
                echo "👇 Скопируй эту строку и вставь в /root/.ssh/authorized_keys на сервере:"
                printf "%b\n" "${C_GREEN}$(cat "${k_path}.pub" 2>/dev/null)${C_RESET}"
                echo ""
                wait_for_enter
            elif [[ "$type_choice" == "2" ]]; then
                echo ""
                printf "%b\n" "${C_RED}☢️  ВНИМАНИЕ! ЭТО СЕКРЕТНЫЙ КЛЮЧ! ☢️${C_RESET}"
                echo "Никому не показывай. Скопируй и сразу очисти экран."
                read -p "Нажми Enter, чтобы показать..."
                echo ""
                cat "$k_path"
                echo ""
                echo "--------------------------------------------------"
                read -p "Нажми Enter, чтобы СКРЫТЬ и очистить экран..."
                clear
            fi
        else
            printf_error "Такого варианта нет. Смотри, что вводишь, босс."
            sleep 1
        fi
    done

    # Восстанавливаем старый trap на CTRL+C
    if [ -n "$old_trap" ]; then
        eval "$old_trap"
    else
        trap - INT
    fi
}

# ============================================================ #
#                    УПРАВЛЕНИЕ БАЗОЙ ФЛОТА                    #
# ============================================================ #

# --- ВЕРСИОННЫЕ ХЕЛПЕРЫ ДЛЯ SKYNET ---
# Нормализация версии: убираем префикс v/V
_skynet_normalize_version() {
    echo "$1" | sed 's/^[vV]//' 2>/dev/null
}

# Возвращает 0 (успех), если локальный ЦУП новее удалённого агента
_skynet_is_local_newer() {
    local local_v remote_v
    local_v=$(_skynet_normalize_version "$1")
    remote_v=$(_skynet_normalize_version "$2")

    # Если одинаковые — обновлять не нужно
    if [[ "$local_v" == "$remote_v" ]]; then
        return 1
    fi

    local top
    top=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -n1)
    if [[ "$top" == "$local_v" ]]; then
        return 0
    fi
    return 1
}

_sanitize_fleet_database() {
    if [ -f "$FLEET_DATABASE_FILE" ]; then
        sed -i '/^$/d' "$FLEET_DATABASE_FILE" # Удаляем пустые строки
    fi
}

_update_fleet_record() {
    local line_num="$1"; local new_record="$2"
    local temp_file; temp_file=$(mktemp)
    awk -v line="$line_num" -v new_rec="$new_record" 'NR==line {print new_rec} NR!=line {print}' "$FLEET_DATABASE_FILE" > "$temp_file"
    mv "$temp_file" "$FLEET_DATABASE_FILE"
}

# ============================================================ #
#                ИСПОЛНЕНИЕ КОМАНД НА ФЛОТЕ (ПЛАГИНЫ)          #
# ============================================================ #

# Выполнить выбранный плагин Skynet на одном сервере
_skynet_run_plugin_on_server() {
    local plugin="$1" name="$2" user="$3" ip="$4" port="$5" key_path="$6"
    printf "\n%b--- Сервер: %s ---%b\n" "${C_YELLOW}" "$name" "${C_RESET}"
    # Копируем плагин на удалённую машину, выполняем через bash (не требуем +x) и удаляем
    scp -q -P "$port" -i "$key_path" "$plugin" "${user}@${ip}:/tmp/reshala_plugin.sh"
    ssh -t -p "$port" -i "$key_path" "${user}@${ip}" "bash /tmp/reshala_plugin.sh; rm -f /tmp/reshala_plugin.sh"
}

_run_fleet_command() {
    local PLUGINS_DIR="${SCRIPT_DIR}/plugins/skynet_commands"
    if [ ! -d "$PLUGINS_DIR" ] || [ -z "$(ls -A "$PLUGINS_DIR")" ]; then
        printf_error "Папка с плагинами пуста или не существует (${PLUGINS_DIR})"; return
    fi
    
    while true; do
        clear; printf_info "--- ВЫБОР КОМАНДЫ ДЛЯ ФЛОТА ---"
        local plugins=(); local i=1
        for p in "$PLUGINS_DIR"/*.sh; do
            if [ -f "$p" ]; then
                local title
                title=$(grep -m1 '^# TITLE:' "$p" 2>/dev/null | sed 's/^# TITLE:[[:space:]]*//')
                if [[ -z "$title" ]]; then
                    title="$(basename "$p" | sed 's/^[0-9]*_//;s/.sh$//')"
                fi
                plugins[$i]=$p
                printf "   [%d] %s\\n" "$i" "$title"
                ((i++))
            fi
        done
        if [ ${#plugins[@]} -eq 0 ]; then
            printf_warning "Нет ни одной команды в ${PLUGINS_DIR}"; wait_for_enter; break
        fi
        echo "   [b] Назад"
        
        local choice; choice=$(safe_read "Какую команду выполнить?: " "")
        if [[ "$choice" == "b" ]]; then break; fi
        if [[ -n "${plugins[$choice]}" ]]; then
            local selected_plugin="${plugins[$choice]}"

            echo ""
            echo "Где выполнять команду?"
            echo "   [1] На ВСЁМ флоте"
            echo "   [2] На ОДНОМ выбранном сервере"
            local scope; scope=$(safe_read "Выбор (1/2): " "1")

            if [[ "$scope" == "2" ]]; then
                if [ ! -s "$FLEET_DATABASE_FILE" ]; then
                    printf_error "База флота пуста. Сначала добавь серверы."
                    wait_for_enter
                    continue
                fi

                local servers=(); local idx=1
                echo ""
                echo "Доступные сервера:"
                while IFS='|' read -r name user ip port key_path sudo_pass; do
                    servers[$idx]="$name|$user|$ip|$port|$key_path"
                    printf "   [%d] %s (%s@%s:%s)\n" "$idx" "$name" "$user" "$ip" "$port"
                    ((idx++))
                done < "$FLEET_DATABASE_FILE"

                local s_choice; s_choice=$(safe_read "Номер сервера: " "")
                if [[ "$s_choice" =~ ^[0-9]+$ ]] && [ -n "${servers[$s_choice]:-}" ]; then
                    IFS='|' read -r name user ip port key_path <<< "${servers[$s_choice]}"
                    printf_warning "Выполняю '${selected_plugin##*/}' на сервере '$name'."
                    read -p "Начать? (y/n): " confirm
                    if [[ "$confirm" == "y" ]]; then
                        _skynet_run_plugin_on_server "$selected_plugin" "$name" "$user" "$ip" "$port" "$key_path"
                        printf_ok "Команда выполнена."; wait_for_enter
                    fi
                fi
            else
                printf_warning "Выполняю '${selected_plugin##*/}' на ВСЁМ флоте. Это может занять время."
                read -p "Начать? (y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    # Читаем базу и выполняем на каждом
                    while IFS='|' read -r name user ip port key_path sudo_pass; do
                        _skynet_run_plugin_on_server "$selected_plugin" "$name" "$user" "$ip" "$port" "$key_path"
                    done < "$FLEET_DATABASE_FILE"
                    printf_ok "Команда выполнена на всём флоте."; wait_for_enter
                fi
            fi
        fi
    done
}

# ============================================================ #
#                ГЛАВНОЕ МЕНЮ УПРАВЛЕНИЯ ФЛОТОМ                #
# ============================================================ #
show_fleet_menu() {
    touch "$FLEET_DATABASE_FILE"

    # CTRL+C в этом меню = "отмена" и возврат в главное
    local old_trap
    old_trap=$(trap -p INT)
    trap 'echo; printf_error "Отмена. Возвращаюсь в главное меню."; break' INT

    while true; do
        _sanitize_fleet_database
        clear
        menu_header "🌐 SKYNET: ЦЕНТР УПРАВЛЕНИЯ ФЛОТОМ"
        echo ""
        echo "   Здесь ты управляешь базой серверов: добавляешь, удаляешь,"
        echo "   редактируешь, смотришь статус и запускаешь команды на всём флоте."
        echo ""

        # --- Параллельный опрос состояния серверов ---
        local servers=()
        local raw_lines=()
        if [ -s "$FLEET_DATABASE_FILE" ]; then
            mapfile -t raw_lines < "$FLEET_DATABASE_FILE"
        fi

        if [ ${#raw_lines[@]} -eq 0 ]; then
            echo -e "\n   (База данных пуста. Добавь свой первый сервер [a])"
        else
            local tmp_dir; tmp_dir=$(mktemp -d)
            printf "\n   %b⏳ Сканирую сеть (параллельный опрос)...%b" "${C_YELLOW}" "${C_RESET}"
            local i=1
            for line in "${raw_lines[@]}"; do
                IFS='|' read -r name user ip port key_path sudo_pass <<< "$line"
                ( timeout 3 ssh -n -q -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -i "$key_path" -p "$port" "$user@$ip" exit 2>/dev/null \
                  && echo "ON" > "$tmp_dir/$i" || echo "OFF" > "$tmp_dir/$i" ) &
                ((i++))
            done
            wait
            printf "\r\033[K" # Стираем строку "Сканирую..."
        fi

        # --- Отрисовка списка серверов ---
        printf "   📂 База данных: ${C_GRAY}%s${C_RESET}\n\n" "$FLEET_DATABASE_FILE"
        echo "Список удаленных серверов:"
        echo "----------------------------------------------------------------"
        local i=1
        if [ ${#raw_lines[@]} -eq 0 ]; then
            echo "   (Пусто)"
        else
            for line in "${raw_lines[@]}"; do
                IFS='|' read -r name user ip port key_path sudo_pass <<< "$line"
                servers[$i]="$line" # Сохраняем полную строку для будущего использования
                local status_text="UNK"; [ -f "$tmp_dir/$i" ] && status_text=$(cat "$tmp_dir/$i")
                local status_color="${C_RED}OFF${C_RESET}"; [[ "$status_text" == "ON" ]] && status_color="${C_GREEN}ON ${C_RESET}"
                local kp_display="Master"; [[ "$key_path" == *"${SKYNET_UNIQUE_KEY_PREFIX}"* ]] && kp_display="Unique"
                local pass_icon=""; if [[ "$user" != "root" && -n "$sudo_pass" ]]; then pass_icon="🔑"; fi
                printf "   [%d] [%b] %b%-15s%b -> %s@%s:%s [%s] %s\n" "$i" "$status_color" "${C_WHITE}" "$name" "${C_RESET}" "$user" "$ip" "$port" "$kp_display" "$pass_icon"
                ((i++))
            done
            rm -rf "$tmp_dir"
        fi
        
        echo "----------------------------------------------------------------"
        printf "   %-3s %-18s %-3s %-16s %-3s %-10s\n" "[a]" "➕ Добавить" "[d]" "🗑️ Удалить" "[k]" "🔑 Ключи"
        printf "   %-3s %-30s\n" "[c]" "☢️  Выполнить команду на флоте"
        printf "   %-3s %-18s %-3s %-10s\n" "[x]" "🗑️  Удалить сервер" "[m]" "📝 Редактор"
        printf "   %-3s %-10s\n" "[b]" "🔙  Назад"
        echo ""

        local choice; choice=$(safe_read "Выбор (или номер сервера для подключения): " "")

        case "$choice" in
            [aA]) # Добавить сервер
                echo; printf_info "--- НОВЫЙ БОЕЦ ---"
                local s_name; s_name=$(safe_read "Имя сервера: " "")
                local s_ip; s_ip=$(safe_read "IP адрес: " "")
                local s_user; s_user=$(safe_read "Пользователь: " "$SKYNET_DEFAULT_USER")
                local s_port; s_port=$(safe_read "SSH порт: " "$SKYNET_DEFAULT_PORT")
                local s_pass=""
                if [[ -z "$s_name" || -z "$s_ip" ]]; then continue; fi

                if [[ "$s_user" != "root" ]]; then
                    printf_warning "Юзер '$s_user' (не root) потребует пароль для команд sudo."
                    read -p "Введи пароль sudo сейчас (или Enter, чтобы пропустить): " -s s_pass; echo
                fi

                echo; echo "Выбери SSH ключ для этого сервера:"
                echo "1) Использовать общий Мастер-ключ (рекомендуется)"
                echo "2) Создать новый УНИКАЛЬНЫЙ ключ"
                local k_choice; k_choice=$(safe_read "Выбор (1/2): " "1")
                local final_key; [[ "$k_choice" == "2" ]] && final_key=$(_generate_unique_key "$s_name") || final_key=$(_ensure_master_key)

                echo; printf_info "🚀 Пробуем закинуть ключ на сервер..."
                if _deploy_key_to_host "$s_ip" "$s_port" "$s_user" "$final_key"; then
                    echo "$s_name|$s_user|$s_ip|$s_port|$final_key|$s_pass" >> "$FLEET_DATABASE_FILE"
                    printf_ok "Сервер '${s_name}' добавлен в флот."

                    # Тестовое подключение по ключу и предложение вырубить вход по паролю
                    if ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$final_key" -p "$s_port" "${s_user}@${s_ip}" "echo OK" >/dev/null 2>&1; then
                        printf_ok "Тестовое подключение по ключу прошло успешно — всё заебись."
                        read -p "Вырубаем вход по паролю и оставляем только ключи? (y/n): " disable_pw
                        if [[ "$disable_pw" == "y" ]]; then
                            if [[ "$s_user" == "root" ]]; then
                                ssh -t -o StrictHostKeyChecking=no -i "$final_key" -p "$s_port" "${s_user}@${s_ip}" "sed -i.bak -E 's/^#?PasswordAuthentication\\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config && (systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null)"
                            elif [[ -n "$s_pass" ]]; then
                                ssh -t -o StrictHostKeyChecking=no -i "$final_key" -p "$s_port" "${s_user}@${s_ip}" "echo '$s_pass' | sudo -S -p '' bash -c 'sed -i.bak -E "s/^#?PasswordAuthentication\\s+.*/PasswordAuthentication no/" /etc/ssh/sshd_config && (systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null)'"
                            else
                                printf_warning "Пароль sudo не указан — не могу безопасно отключить парольный вход."
                            fi
                        fi
                    fi

                    sleep 1
                else
                    printf_error "Не удалось добавить сервер. Проверь данные."
                fi
                ;;

            [dD]) # Удалить сервер
                local del_num; del_num=$(safe_read "Номер сервера для удаления: " "")
                if [[ "$del_num" =~ ^[0-9]+$ ]] && [ -n "${servers[$del_num]:-}" ]; then
                    sed -i "${del_num}d" "$FLEET_DATABASE_FILE"
                    printf_ok "Сервер удалён." && sleep 1
                fi
                ;;

            [kK]) _show_keys_menu ;;
            [mM]) ensure_package "nano"; nano "$FLEET_DATABASE_FILE" ;;
            [xX])
                read -p "Ты ТОЧНО хочешь удалить ВСЕ серверы из базы? (yes/no): " confirm
                if [[ "$confirm" == "yes" ]]; then > "$FLEET_DATABASE_FILE"; printf_ok "База флота уничтожена."; sleep 1; fi
                ;;
            [bB]) break ;;
            [cC]) _run_fleet_command ;;
            *) # Подключение к серверу по номеру
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ -n "${servers[$choice]:-}" ]; then
                    IFS='|' read -r s_name s_user s_ip s_port s_key s_pass <<< "${servers[$choice]}"
                    
                    clear; printf_info "🚀 SKYNET UPLINK: Подключаюсь к ${s_name}..."

                    # Проверяем/запрашиваем пароль sudo, если нужен
                    if [[ "$s_user" != "root" && -z "$s_pass" ]]; then
                        printf_warning "Для управления этим сервером нужен пароль sudo."
                        read -p "Введи пароль для '$s_user': " -s s_pass; echo
                        read -p "Сохранить этот пароль в базу? (y/n): " save_pass
                        if [[ "$save_pass" == "y" ]]; then
                            _update_fleet_record "$choice" "$s_name|$s_user|$s_ip|$s_port|$s_key|$s_pass"
                            printf_ok "Пароль сохранён."
                        fi
                    fi
                    
                    # Команда для удаленного выполнения
                    run_remote() {
                        if [[ "$s_user" == "root" ]]; then
                            ssh -o StrictHostKeyChecking=no -i "$s_key" -p "$s_port" "$s_user@$s_ip" "$1"
                        else
                            # Пытаемся выполнить с sudo, передавая пароль
                            ssh -o StrictHostKeyChecking=no -i "$s_key" -p "$s_port" "$s_user@$s_ip" "echo '$s_pass' | sudo -S -p '' bash -c '$1'"
                        fi
                    }

                    # Проверка доступа и синхронизация агента
                    printf "   📡 Проверка связи и версии агента... "
                    local remote_ver; remote_ver=$(run_remote "if [ -f $INSTALL_PATH ]; then grep 'readonly VERSION' $INSTALL_PATH | cut -d'\"' -f2; else echo 'NONE'; fi" | tail -n1 | tr -d '\r')
                    
                    # Если агента нет ИЛИ локальная версия ЦУПа новее — ставим/обновляем
                    if [[ -z "$remote_ver" || "$remote_ver" == "NONE" ]] || _skynet_is_local_newer "$VERSION" "$remote_ver"; then
                        printf "%b\n" "${C_YELLOW}Требуется установка/обновление агента...${C_RESET}"
                        printf_info "Это может занять 30–90 секунд, не трогай клавиатуру."

                        # Ставим агента через полноценный install.sh, но тихо (логи на удалённой стороне).
                        # ВАЖНО: без sudo здесь, run_remote сам поднимет привилегии при необходимости.
                        # Передаём переменную RESHALA_NO_AUTOSTART=1, чтобы инсталлятор НЕ запускал Решалу интерактивно.
                        local install_cmd="RESHALA_NO_AUTOSTART=1 wget -q -O /tmp/reshala_install.sh ${INSTALLER_URL_RAW} >/dev/null 2>&1 && RESHALA_NO_AUTOSTART=1 bash /tmp/reshala_install.sh >/tmp/reshala_install.log 2>&1 && rm /tmp/reshala_install.sh"

                        # Выполняем установку синхронно (без фона), просто предупреждаем пользователя, что это займёт время
                        if ! run_remote "$install_cmd"; then
                           printf_error "Не удалось установить/обновить агента. Вход невозможен."
                           continue
                        fi
                        printf_ok "Агент успешно развёрнут."
                    else
                        printf "%b\n" "${C_GREEN}OK (${remote_ver})${C_RESET}"
                    fi

                    # Телепортация!
                    printf_info "Вхожу в удалённый терминал..."
                    sleep 1
                    
                    local ssh_command="ssh -t -o StrictHostKeyChecking=no -i '$s_key' -p '$s_port' '$s_user@$s_ip'"
                    local remote_exec_command="sudo SKYNET_MODE=1 $INSTALL_PATH"
                    
                    if [[ "$s_user" == "root" ]]; then
                        eval "$ssh_command '$remote_exec_command'"
                    else
                        # Сложная команда, чтобы sudo-сессия жила дольше
                        local sudo_wrapper="echo '$s_pass' | sudo -S -p '' bash -c \\\"$remote_exec_command\\\""
                        eval "$ssh_command \"$sudo_wrapper\""
                    fi

                    printf "\n%b\n" "${C_CYAN}🔙 Связь с ${s_name} завершена.${C_RESET}"; sleep 1
                fi
                ;;
        esac
    done

    # Восстанавливаем trap
    if [ -n "$old_trap" ]; then
        eval "$old_trap"
    else
        trap - INT
    fi
}
