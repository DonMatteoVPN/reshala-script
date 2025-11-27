#!/bin/bash
# ============================================================ #
# ==       REMNAWAVE: КАСТОМНЫЕ ПОДПИСКИ ОТ LEGIZ            == #
# ============================================================ #
# Полный перенос легизовских фич для страницы подписки:
#  - META_TITLE / META_DESCRIPTION;
#  - выбор шаблона (sub‑page / Orion / Material / Marzbanify);
#  - кастомный список приложений и брендирование (app-config.json).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# --- META_TITLE / META_DESCRIPTION ------------------------------

# Вытаскиваем текущие значения META_TITLE / META_DESCRIPTION из docker-compose,
# если панель уже установлена. Это нужно для Legiz‑меню, чтобы показать текущий бренд.
_remna_legiz_get_current_meta() {
    local compose="/opt/remnawave/docker-compose.yml"
    local title="" desc=""
    if [[ -f "$compose" ]]; then
        title=$(grep -E 'META_TITLE=' "$compose" 2>/dev/null | head -n1 | sed 's/.*META_TITLE=//') || true
        desc=$(grep -E 'META_DESCRIPTION=' "$compose" 2>/dev/null | head -n1 | sed 's/.*META_DESCRIPTION=//') || true
    fi
    echo "$title" "$desc"
}

# Обновляем META_TITLE / META_DESCRIPTION в docker-compose и перезапускаем страницу подписки
_remna_legiz_update_meta() {
    local new_title="$1"
    local new_desc="$2"
    local compose="/opt/remnawave/docker-compose.yml"

    if [[ ! -f "$compose" ]]; then
        err "Не найден $compose. Похоже, панель Remnawave ещё не установлена на этом сервере."
        return 1
    fi

    info "Обновляю META_TITLE и META_DESCRIPTION в docker-compose Remnawave..."

    if grep -q 'META_TITLE=' "$compose"; then
        run_cmd sed -i "s|META_TITLE=.*|META_TITLE=$new_title|" "$compose" || return 1
    else
        warn "Не нашёл строку META_TITLE= в $compose. Проверь раздел окружения remnawave-subscription-page."
    fi

    if grep -q 'META_DESCRIPTION=' "$compose"; then
        run_cmd sed -i "s|META_DESCRIPTION=.*|META_DESCRIPTION=$new_desc|" "$compose" || return 1
    else
        warn "Не нашёл строку META_DESCRIPTION= в $compose. Проверь раздел окружения remnawave-subscription-page."
    fi

    info "Перезапускаю контейнеры страницы подписки и фронтового nginx..."
    if ( cd /opt/remnawave && run_cmd docker compose up -d remnawave-subscription-page remnawave-nginx ); then
        ok "Новый заголовок/описание применены. Обнови страницу подписки в браузере."
    else
        warn "Не удалось корректно перезапустить контейнеры. Проверь docker compose ps и логи remnawave-subscription-page/remnawave-nginx."
    fi

    return 0
}

# --- ВСПОМОГАТЕЛЬНЫЕ ХЕЛПЕРЫ ДЛЯ LEGIZ -------------------------

_remna_legiz_ensure_yq_installed() {
    if command -v /usr/bin/yq >/dev/null 2>&1 || command -v yq >/dev/null 2>&1; then
        return 0
    fi

    info "Нужен yq для работы с docker-compose.yml (Legiz‑шаблоны). Скачиваю бинарник..."
    if ! wget -q "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -O /usr/bin/yq; then
        err "Не смог скачать yq с GitHub. Проверь соединение или установи yq вручную."
        return 1
    fi
    if ! chmod +x /usr/bin/yq; then
        err "Не удалось выдать права на исполнение /usr/bin/yq."
        return 1
    fi

    if ! /usr/bin/yq --version >/dev/null 2>&1; then
        err "yq установлен, но не запускается. Проверь /usr/bin/yq вручную."
        return 1
    fi

    ok "yq установлен и готов работать."
    return 0
}

_remna_legiz_download_with_fallback() {
    local primary_url="$1"
    local fallback_url="$2"
    local output_file="$3"

    if curl -s -L -f -o "$output_file" "$primary_url"; then
        return 0
    fi

    warn "Основной источник недоступен, пробую запасное зеркало..."
    if curl -s -L -f -o "$output_file" "$fallback_url"; then
        return 0
    fi

    return 1
}

_remna_legiz_restart_subscription_page() {
    local compose_dir="/opt/remnawave"
    if [[ ! -d "$compose_dir" ]]; then
        err "Каталог $compose_dir не найден. Похоже, панель ещё не установлена."
        return 1
    fi

    info "Перезапускаю контейнер remnawave-subscription-page (страница подписки)..."
    if ( cd "$compose_dir" && run_cmd docker compose down remnawave-subscription-page && run_cmd docker compose up -d remnawave-subscription-page ); then
        ok "Страница подписки перезапущена."
        return 0
    fi

    warn "Не удалось корректно перезапустить remnawave-subscription-page. Проверь docker compose ps и логи контейнера."
    return 1
}

_remna_legiz_check_subscription_env() {
    local compose="/opt/remnawave/docker-compose.yml"
    if [[ ! -f "$compose" ]]; then
        err "Не найден $compose. Похоже, панель Remnawave ещё не установлена."
        return 1
    fi

    # Проверим, что контейнер страницы подписки вообще существует в стеке
    if ! docker ps -a --filter "name=remnawave-subscription-page" --format '{{.Names}}' | grep -q "^remnawave-subscription-page$"; then
        err "Контейнер remnawave-subscription-page пока не найден. Сначала поставь/запусти панель Remnawave."
        return 1
    fi

    return 0
}

# --- ШАБЛОНЫ СТРАНИЦЫ ПОДПИСКИ (sub-page / Orion / и т.п.) ----

_remna_legiz_show_sub_page_menu() {
    echo
    info "Выбор шаблона страницы подписки Remnawave (Legiz)."
    echo "   1) Простой app-config (simple custom app list: Clash/Sing)"
    echo "   2) Мульти‑приложения (multiapp custom app list)"
    echo "   3) Только HWID‑вариант (HWID only custom app list)"
    echo
    echo "   4) Orion web‑страница (поддерживает app-config)"
    echo "   5) Material web‑страница (поддерживает app-config)"
    echo "   6) Marzbanify web‑страница (Clash и Sing)"
    echo
    echo "   7) Сбросить настройки страницы подписки (убрать кастомные файлы)"
    echo
    echo "   [b] 🔙 Назад"
}

_remna_legiz_manage_sub_page_upload() {
    if ! _remna_legiz_check_subscription_env; then
        return 1
    fi
    if ! _remna_legiz_ensure_yq_installed; then
        return 1
    fi

    local config_file="/opt/remnawave/app-config.json"
    local index_file="/opt/remnawave/index.html"
    local docker_compose_file="/opt/remnawave/docker-compose.yml"

    # Чистим старые кастомные файлы если они были каталогами (на всякий случай)
    if [[ -d "$config_file" || -d "$index_file" ]]; then
        rm -rf "$config_file" "$index_file"
    fi

    while true; do
        clear
        menu_header "REMNAWAVE: ШАБЛОНЫ СТРАНИЦЫ ПОДПИСКИ (LEGIZ)"
        _remna_legiz_show_sub_page_menu
        echo "------------------------------------------------------"

        local opt
        opt=$(safe_read "Твой выбор: " "") || return 130

        case "$opt" in
            1|2|3)
                # Только app-config.json (без index.html)
                [[ -f "$index_file" ]] && rm -f "$index_file"

                info "Скачиваю app-config.json от Legiz..."
                local primary_url fallback_url
                primary_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/app-config.json"
                fallback_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/app-config.json"
                if [[ "$opt" == "2" ]]; then
                    primary_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/multiapp/app-config.json"
                    fallback_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/multiapp/app-config.json"
                elif [[ "$opt" == "3" ]]; then
                    primary_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/hwid/app-config.json"
                    fallback_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/hwid/app-config.json"
                fi

                if ! _remna_legiz_download_with_fallback "$primary_url" "$fallback_url" "$config_file"; then
                    err "Не удалось скачать app-config.json для страницы подписки."
                    wait_for_enter || true
                    return 1
                fi

                _remna_legiz_branding_add_to_appconfig "$config_file"

                # Прописываем volume только с app-config.json
                /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
                /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./app-config.json:/opt/app/frontend/assets/app-config.json"]' -i "$docker_compose_file"
                ;;

            4|5)
                # Orion / Material: index.html (+ опциональный app-config)
                [[ -f "$config_file" ]] && rm -f "$config_file"
                [[ -f "$index_file" ]] && rm -f "$index_file"

                info "Скачиваю HTML‑шаблон страницы подписки..."
                local primary_index_url fallback_index_url
                if [[ "$opt" == "4" ]]; then
                    primary_index_url="https://raw.githubusercontent.com/legiz-ru/Orion/refs/heads/main/index.html"
                    fallback_index_url="https://cdn.jsdelivr.net/gh/legiz-ru/Orion@main/index.html"
                else
                    primary_index_url="https://raw.githubusercontent.com/legiz-ru/material-remnawave-subscription-page/refs/heads/main/index.html"
                    fallback_index_url="https://cdn.jsdelivr.net/gh/legiz-ru/material-remnawave-subscription-page@main/index.html"
                fi

                if ! _remna_legiz_download_with_fallback "$primary_index_url" "$fallback_index_url" "$index_file"; then
                    err "Не удалось скачать index.html для страницы подписки."
                    wait_for_enter || true
                    return 1
                fi

                echo
                info "Можно дополнительно подтянуть app-config.json (список приложений и брендирование)."
                echo "   1) Простой app-config (simple)"
                echo "   2) Мульти‑приложения (multiapp)"
                echo "   3) HWID‑вариант"
                echo "   0) Не трогать app-config (оставить только HTML)"
                local sub_opt
                sub_opt=$(safe_read "Нужен ли отдельный app-config? [0‑3]: " "0") || return 130

                if [[ "$sub_opt" == "1" || "$sub_opt" == "2" || "$sub_opt" == "3" ]]; then
                    local primary_config_url fallback_config_url
                    primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/app-config.json"
                    fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/app-config.json"
                    if [[ "$sub_opt" == "2" ]]; then
                        primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/multiapp/app-config.json"
                        fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/multiapp/app-config.json"
                    elif [[ "$sub_opt" == "3" ]]; then
                        primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/hwid/app-config.json"
                        fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/hwid/app-config.json"
                    fi

                    if ! _remna_legiz_download_with_fallback "$primary_config_url" "$fallback_config_url" "$config_file"; then
                        err "Не удалось скачать app-config.json для выбранного режима."
                        wait_for_enter || true
                        return 1
                    fi

                    _remna_legiz_branding_add_to_appconfig "$config_file"
                else
                    [[ -f "$config_file" ]] && rm -f "$config_file"
                fi

                /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
                /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$docker_compose_file"
                if [[ -f "$config_file" ]]; then
                    /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./app-config.json:/opt/app/frontend/assets/app-config.json"]' -i "$docker_compose_file"
                fi
                ;;

            6)
                # Marzbanify: только index.html без app-config
                [[ -f "$config_file" ]] && rm -f "$config_file"
                [[ -f "$index_file" ]] && rm -f "$index_file"

                info "Скачиваю Marzbanify‑страницу подписки (index.html)..."
                local primary_url fallback_url
                primary_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/customweb/clash-sing/index.html"
                fallback_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/customweb/clash-sing/index.html"
                if ! _remna_legiz_download_with_fallback "$primary_url" "$fallback_url" "$index_file"; then
                    err "Не удалось скачать Marzbanify index.html."
                    wait_for_enter || true
                    return 1
                fi

                /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
                /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$docker_compose_file"
                ;;

            7)
                info "Сбрасываю кастомные файлы страницы подписки (index.html/app-config.json)..."
                [[ -f "$config_file" ]] && rm -f "$config_file"
                [[ -f "$index_file" ]] && rm -f "$index_file"
                /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
                ;;

            [bB])
                return 0
                ;;

            *)
                err "Нет такого пункта, выбери пункт из списка."
                wait_for_enter || true
                continue
                ;;
        esac

        # Небольшая зачистка YAML после правок yq (убираем комментарии и хвостовые пустые строки)
        /usr/bin/yq eval -i '... comments=""' "$docker_compose_file" || true
        sed -i '/./,$!d' "$docker_compose_file" || true

        _remna_legiz_restart_subscription_page || true
        wait_for_enter || true
    done
}

# --- КАСТОМНЫЙ СПИСОК ПРИЛОЖЕНИЙ И БРЕНД -----------------------

_remna_legiz_branding_add_to_appconfig() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        err "Не нашёл файл конфигурации: $config_file"
        return 1
    fi

    echo
    info "Добавить блок брендирования в app-config.json? (имя проекта, ссылка поддержки, логотип)"
    local ans
    ans=$(safe_read "Добавлять брендирование? (Y/n): " "y") || return 130
    if [[ "$ans" == "n" || "$ans" == "N" ]]; then
        info "Ок, оставляем app-config.json без брендирования."
        return 0
    fi

    local BRAND_NAME SUPPORT_URL LOGO_URL
    BRAND_NAME=$(safe_read "Название проекта/бренда (будет отображаться в интерфейсе): " "") || return 130
    SUPPORT_URL=$(safe_read "Ссылка для поддержки/контакта (можно пустую): " "") || return 130
    LOGO_URL=$(safe_read "URL логотипа (PNG/SVG, можно пустой): " "") || return 130

    jq \
        --arg name "$BRAND_NAME" \
        --arg supportUrl "$SUPPORT_URL" \
        --arg logoUrl "$LOGO_URL" \
        '.config.branding = {"name": $name, "supportUrl": $supportUrl, "logoUrl": $logoUrl}' \
        "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"

    ok "Блок брендирования добавлен в app-config.json."
    return 0
}

_remna_legiz_show_custom_app_menu() {
    echo
    info "Управление кастомным списком приложений/брендом (app-config.json)."
    echo "   1) Изменить бренд (логотип/имя/ссылку поддержки)"
    echo "   2) Удалить приложение из списка (по платформе)"
    echo
    echo "   [b] 🔙 Назад"
}

_remna_legiz_edit_branding() {
    local config_file="$1"
    local needs_restart=false

    if ! [[ -f "$config_file" ]]; then
        err "Не найден $config_file. Сначала выбери любой шаблон с app-config.json в меню Legiz."
        return 1
    fi

    echo
    info "Текущие значения брендирования (если есть):"
    local logo_url name support_url
    logo_url=$(jq -r '.config.branding.logoUrl // "N/A"' "$config_file" 2>/dev/null || echo "N/A")
    name=$(jq -r '.config.branding.name // "N/A"' "$config_file" 2>/dev/null || echo "N/A")
    support_url=$(jq -r '.config.branding.supportUrl // "N/A"' "$config_file" 2>/dev/null || echo "N/A")

    info "Лого:        $logo_url"
    info "Имя бренда:  $name"
    info "Ссылка саппорта: $support_url"

    echo
    echo "   1) Изменить URL логотипа"
    echo "   2) Изменить название бренда"
    echo "   3) Изменить ссылку поддержки"
    echo
    echo "   [b] 🔙 Назад"

    local choice
    choice=$(safe_read "Твой выбор: " "") || return 130

    case "$choice" in
        1)
            local new_logo confirm
            new_logo=$(safe_read "Новый URL логотипа: " "$logo_url") || return 130
            confirm=$(safe_read "Точно меняем лого? (Y/n): " "y") || return 130
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                jq --arg logo "$new_logo" '.config.branding.logoUrl = $logo' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        2)
            local new_name confirm2
            new_name=$(safe_read "Новое имя бренда: " "$name") || return 130
            confirm2=$(safe_read "Точно меняем имя? (Y/n): " "y") || return 130
            if [[ "$confirm2" == "y" || "$confirm2" == "Y" ]]; then
                jq --arg nm "$new_name" '.config.branding.name = $nm' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        3)
            local new_support confirm3
            new_support=$(safe_read "Новая ссылка поддержки: " "$support_url") || return 130
            confirm3=$(safe_read "Точно меняем ссылку? (Y/n): " "y") || return 130
            if [[ "$confirm3" == "y" || "$confirm3" == "Y" ]]; then
                jq --arg sp "$new_support" '.config.branding.supportUrl = $sp' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        [bB])
            return 0
            ;;
        *)
            err "Нет такого пункта."
            return 1
            ;;
    esac

    if [[ "$needs_restart" == true ]]; then
        _remna_legiz_restart_subscription_page || true
    fi

    return 0
}

_remna_legiz_delete_applications() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        err "Не найден $config_file. Сначала выбери шаблон с app-config.json (через меню шаблонов)."
        return 1
    fi

    local platforms
    platforms=$(jq -r '.platforms | to_entries[] | select(.value | length > 0) | .key' "$config_file" 2>/dev/null || true)
    if [[ -z "$platforms" ]]; then
        err "В app-config.json нет ни одной платформы с приложениями."
        return 1
    fi

    echo
    info "Выбери платформу, из которой удалим приложение:"
    local i=1
    declare -A platform_map
    while IFS= read -r platform; do
        [[ -z "$platform" ]] && continue
        printf "   %d) %s\n" "$i" "$platform"
        platform_map[$i]="$platform"
        ((i++))
    done <<< "$platforms"
    echo "   0) Назад"

    local p_choice
    p_choice=$(safe_read "Номер платформы: " "0") || return 130
    if [[ "$p_choice" == "0" ]]; then
        return 0
    fi
    if [[ -z "${platform_map[$p_choice]:-}" ]]; then
        err "Нет такой платформы."
        return 1
    fi

    local selected_platform="${platform_map[$p_choice]}"

    local apps
    apps=$(jq -r --arg platform "$selected_platform" '.platforms[$platform][] | .name // .id' "$config_file" 2>/dev/null || true)
    if [[ -z "$apps" ]]; then
        err "В выбранной платформе нет приложений."
        return 1
    fi

    echo
    info "Выбери приложение, которое нужно удалить:"
    local j=1
    declare -A app_map
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        printf "   %d) %s\n" "$j" "$app"
        app_map[$j]="$app"
        ((j++))
    done <<< "$apps"
    echo "   0) Назад"

    local a_choice
    a_choice=$(safe_read "Номер приложения: " "0") || return 130
    if [[ "$a_choice" == "0" ]]; then
        return 0
    fi
    if [[ -z "${app_map[$a_choice]:-}" ]]; then
        err "Нет такого приложения."
        return 1
    fi

    local selected_app="${app_map[$a_choice]}"
    local confirm
    confirm=$(safe_read "Удаляем приложение '$selected_app' с платформы '$selected_platform'? (Y/n): " "y") || return 130
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Ок, ничего не удаляем."
        return 0
    fi

    jq --arg platform "$selected_platform" --arg app_name "$selected_app" '
        .platforms[$platform] = [.platforms[$platform][] | select((.name // .id) != $app_name)]
    ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"

    ok "Приложение удалено из app-config.json."
    _remna_legiz_restart_subscription_page || true
    return 0
}

_remna_legiz_manage_custom_app_list() {
    local config_file="/opt/remnawave/app-config.json"

    if [[ ! -f "$config_file" ]]; then
        err "Не найден $config_file. Сначала выбери любой шаблон в Legiz‑меню, который создаёт app-config.json."
        return 1
    fi

    while true; do
        clear
        menu_header "REMNAWAVE: КАСТОМНЫЙ СПИСОК ПРИЛОЖЕНИЙ (LEGIZ)"
        _remna_legiz_show_custom_app_menu
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "") || return 130

        case "$choice" in
            1)
                _remna_legiz_edit_branding "$config_file"
                wait_for_enter || true
                ;;
            2)
                _remna_legiz_delete_applications "$config_file"
                wait_for_enter || true
                ;;
            [bB])
                return 0
                ;;
            *)
                err "Нет такого пункта."
                wait_for_enter || true
                ;;
        esac
    done
}

# --- ГЛАВНОЕ МЕНЮ LEGIZ ----------------------------------------

show_remnawave_legiz_menu() {
    enable_graceful_ctrlc
    while true; do
        clear
        menu_header "REMNAWAVE: КАСТОМНЫЕ ПОДПИСКИ (LEGIZ)"
        echo
        echo "   1) META_TITLE / META_DESCRIPTION страницы подписки"
        echo "   2) Шаблоны страницы подписки от Legiz (sub‑page / Orion / Material / Marzbanify)"
        echo "   3) Кастомный список приложений и брендирование (app-config.json)"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "") || break

        case "$choice" in
            1)
                local cur_title cur_desc
                read -r cur_title cur_desc < <(_remna_legiz_get_current_meta)
                echo
                info "Текущий META_TITLE:       ${cur_title:-<не задан>}"
                info "Текущий META_DESCRIPTION: ${cur_desc:-<не задан>}"
                echo
                local new_title new_desc
                new_title=$(safe_read "Новый заголовок (META_TITLE) для страницы подписки: " "${cur_title:-Remnawave Subscription}") || break
                new_desc=$(safe_read "Новое описание (META_DESCRIPTION) для страницы подписки: " "${cur_desc:-page}") || break

                if [[ -z "$new_title" ]]; then
                    err "Заголовок не может быть пустым."
                    wait_for_enter || true
                    continue
                fi

                _remna_legiz_update_meta "$new_title" "$new_desc"
                wait_for_enter || true
                ;;
            2)
                _remna_legiz_manage_sub_page_upload
                ;;
            3)
                _remna_legiz_manage_custom_app_list
                ;;
            [bB])
                break
                ;;
            *)
                err "Нет такого пункта, смотри внимательнее, босс."
                wait_for_enter || true
                ;;
        esac
    done
    disable_graceful_ctrlc
}
