#!/bin/bash
# ============================================================ #
# ==            REMNAWAVE: УПРАВЛЕНИЕ ПАНЕЛЬ/НОДОЙ           == #
# ============================================================ #
# Здесь будет реализована логика start/stop/update/logs/CLI/8443
# для панели и нод Remnawave. Пока заглушка.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# Вспомогательный выбор, с чем работаем: панель или локальная нода
# Возвращает строку "panel" или "node" через stdout, либо завершает с ошибкой.
_remna_manage_select_stack() {
    local action_desc="$1"
    local panel_compose="/opt/remnawave/docker-compose.yml"
    local node_compose="/opt/remnanode/docker-compose.yml"

    local has_panel=false has_node=false
    [[ -f "$panel_compose" ]] && has_panel=true
    [[ -f "$node_compose"  ]] && has_node=true

    if [[ "$has_panel" == false && "$has_node" == false ]]; then
        err "Не нашёл ни одной установки Remnawave на этом сервере (нет /opt/remnawave или /opt/remnanode)."
        info "Сначала установи панель/ноду через меню установки, потом уже можно ими управлять."
        return 1
    fi

    if [[ "$has_panel" == true && "$has_node" == false ]]; then
        echo "panel"
        return 0
    fi
    if [[ "$has_panel" == false && "$has_node" == true ]]; then
        echo "node"
        return 0
    fi

    # Если есть и панель, и локальная нода — спрашиваем, чем управлять
    echo
    info "Выбери, чем именно управлять ($action_desc):"
    echo "   1) Панель (директория /opt/remnawave)"
    echo "   2) Локальная нода (директория /opt/remnanode)"
    echo
    local ch
    ch=$(safe_read "Твой выбор (1/2): " "1") || return 1
    case "$ch" in
        1) echo "panel" ;;
        2) echo "node"  ;;
        *) err "Некорректный выбор."; return 1 ;;
    esac
}

show_remnawave_manage_menu() {
    enable_graceful_ctrlc
    while true; do
        clear
        menu_header "УПРАВЛЕНИЕ ПАНЕЛЬЮ И НОДОЙ REMNAWAVE"
        echo
        echo "   1) Запустить панель/ноду"
        echo "   2) Остановить панель/ноду"
        echo "   3) Обновить панель/ноду (docker compose pull + up -d)"
        echo "   4) Смотреть логи (docker compose logs -f)"
        echo "   5) Remnawave CLI (shell внутри контейнера панели)"
        echo "   6) Подсказка по доступу к панели через порт 8443"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "") || break

        case "$choice" in
            1)
                local target
                target=$(_remna_manage_select_stack "запустить") || { wait_for_enter || true; continue; }
                if [[ "$target" == "panel" ]]; then
                    info "Запускаю стэк Remnawave панели (docker compose up -d в /opt/remnawave)..."
                    if ( cd /opt/remnawave && run_cmd docker compose up -d ); then
                        ok "Панельный стэк Remnawave запущен."
                    else
                        err "docker compose up -d для панели отработал с ошибкой. Смотри docker-логи контейнеров remnawave/*."
                    fi
                else
                    info "Запускаю локальную ноду Remnawave (docker compose up -d в /opt/remnanode)..."
                    if ( cd /opt/remnanode && run_cmd docker compose up -d ); then
                        ok "Локальная нода Remnawave запущена."
                    else
                        err "docker compose up -d для локальной ноды отработал с ошибкой. Смотри docker-логи remnanode/*."
                    fi
                fi
                wait_for_enter || true
                ;;
            2)
                local target
                target=$(_remna_manage_select_stack "остановить") || { wait_for_enter || true; continue; }
                if [[ "$target" == "panel" ]]; then
                    info "Останавливаю стэк Remnawave панели (docker compose down в /opt/remnawave)..."
                    if ( cd /opt/remnawave && run_cmd docker compose down ); then
                        ok "Панельный стэк Remnawave остановлен."
                    else
                        err "docker compose down для панели отработал с ошибкой. Смотри docker-логи remnawave/*."
                    fi
                else
                    info "Останавливаю локальную ноду Remnawave (docker compose down в /opt/remnanode)..."
                    if ( cd /opt/remnanode && run_cmd docker compose down ); then
                        ok "Локальная нода Remnawave остановлена."
                    else
                        err "docker compose down для локальной ноды отработал с ошибкой. Смотри docker-логи remnanode/*."
                    fi
                fi
                wait_for_enter || true
                ;;
            3)
                local target
                target=$(_remna_manage_select_stack "обновить") || { wait_for_enter || true; continue; }
                if [[ "$target" == "panel" ]]; then
                    info "Обновляю и перезапускаю панель Remnawave (docker compose pull && up -d в /opt/remnawave)..."
                    if ( cd /opt/remnawave && run_cmd docker compose pull && run_cmd docker compose up -d ); then
                        ok "Панельный стэк Remnawave обновлён и запущен."
                    else
                        err "Обновление панели через docker compose pull/up -d отработало с ошибкой. Смотри docker-логи."
                    fi
                else
                    info "Обновляю и перезапускаю локальную ноду Remnawave (docker compose pull && up -d в /opt/remnanode)..."
                    if ( cd /opt/remnanode && run_cmd docker compose pull && run_cmd docker compose up -d ); then
                        ok "Локальная нода Remnawave обновлена и запущена."
                    else
                        err "Обновление локальной ноды через docker compose pull/up -d отработало с ошибкой. Смотри docker-логи."
                    fi
                fi
                wait_for_enter || true
                ;;
            4)
                local target
                target=$(_remna_manage_select_stack "смотреть логи") || { wait_for_enter || true; continue; }
                if [[ "$target" == "panel" ]]; then
                    local compose_path="/opt/remnawave/docker-compose.yml"
                    if [[ ! -f "$compose_path" ]]; then
                        err "Не нашёл $compose_path. Похоже, панель ещё не установлена через это меню."
                    else
                        info "Открываю поток логов стэка Remnawave (панель). CTRL+C — чтобы вернуться назад."
                        view_docker_logs "$compose_path" "Remnawave panel stack"
                    fi
                else
                    local compose_path="/opt/remnanode/docker-compose.yml"
                    if [[ ! -f "$compose_path" ]]; then
                        err "Не нашёл $compose_path. Похоже, локальная нода ещё не установлена через это меню."
                    else
                        info "Открываю поток логов локальной ноды Remnawave. CTRL+C — чтобы вернуться назад."
                        view_docker_logs "$compose_path" "Remnawave local node"
                    fi
                fi
                ;;
            5)
                # CLI имеет смысл только для панели (контейнер remnawave)
                if [[ ! -f "/opt/remnawave/docker-compose.yml" ]]; then
                    err "Похоже, панель Remnawave ещё не установлена (нет /opt/remnawave/docker-compose.yml)."
                    info "Сначала установи панель через меню установки."
                    wait_for_enter || true
                else
                    info "Открываю shell внутри контейнера панели Remnawave (docker exec -it remnawave sh)."
                    info "После завершения работы в CLI просто нажми CTRL+D или exit."
                    ( cd /opt/remnawave && run_cmd docker exec -it remnawave sh )
                    wait_for_enter || true
                fi
                ;;
            6)
                echo
                info "Порт 8443 — это просто удобный локальный туннель до панели Remnawave."
                info "Сам скрипт ничего не открывает в интернет, но подскажет, как пробросить порт."
                echo
                echo "Например, если панель крутится на удалённом сервере, можно сделать так (пример):"
                echo
                echo "   ssh -L 8443:127.0.0.1:3000 user@REMOTE_SERVER_IP"
                echo
                info "После этого на СВОЁМ компьютере открывай в браузере: http://127.0.0.1:8443"
                info "Это будет прокинутый backend панели (порт 3000) через SSH-туннель."
                echo
                warn "Команду выше нужно адаптировать под свои user@host и ключи/пароли SSH."
                wait_for_enter || true
                ;;
            [bB])
                break
                ;;
            *)
                err "Нет такого пункта, смотри внимательнее, босс."
                ;;
        esac
    done
    disable_graceful_ctrlc
}
