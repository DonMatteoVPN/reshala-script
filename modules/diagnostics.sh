#!/bin/bash
# ============================================================ #
# ==                МОДУЛЬ ДИАГНОСТИКИ                      == #
# ============================================================ #
#
# Отвечает за просмотр логов и управление Docker.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

_show_docker_cleanup_menu() {
    while true; do
        clear; echo "--- УПРАВЛЕНИЕ DOCKER: ОЧИСТКА ДИСКА ---"
        echo "----------------------------------------"; 
        echo "   1. 📊 Показать самые большие образы"; 
        echo "   2. 🧹 Простая очистка (висячие образы, кэш)"; 
        echo "   3. 💥 Полная очистка неиспользуемых образов"; 
        echo "   4. 🗑️ Очистка неиспользуемых томов (ОСТОРОЖНО!)"; 
        echo "   5. 📈 Показать итоговое использование диска"; 
        echo "   b. Назад"
        echo "----------------------------------------"; 
        local choice; read -r -p "Твой выбор: " choice
        case "$choice" in
            1) echo; docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" | sort -rh | head; wait_for_enter ;;
            2) docker system prune -f; printf_ok "Простая очистка завершена."; wait_for_enter ;;
            3) read -p "Удалить ВСЕ неиспользуемые образы? (y/n): " c; if [[ "$c" == "y" ]]; then docker image prune -a -f; printf_ok "Полная очистка завершена."; fi; wait_for_enter ;;
            4) printf_error "ОСТОРОЖНО! Удаляет ВСЕ тома, не привязанные к контейнерам!"; read -p "Точно продолжить? (y/n): " c; if [[ "$c" == "y" ]]; then docker volume prune -f; printf_ok "Очистка томов завершена."; fi; wait_for_enter ;;
            5) echo; docker system df; wait_for_enter ;;
            [bB]) break ;;
        esac
    done
}

# Дополнительные меню управления Docker
_show_docker_containers_menu() {
    while true; do
        clear
        echo "--- DOCKER: КОНТЕЙНЕРЫ ---"
        echo "----------------------------------------"
        echo "   1. 📦 Список контейнеров (docker ps -a)"
        echo "   2. 📜 Логи контейнера (docker logs)"
        echo "   3. ▶️ Старт / ⏹ Стоп / 🔁 Рестарт контейнера"
        echo "   4. 🗑️ Удалить контейнер (stop + rm)"
        echo "   b. Назад"
        echo "----------------------------------------"
        local choice; read -r -p "Твой выбор: " choice || continue
        case "$choice" in
            1) echo; docker ps -a; wait_for_enter ;;
            2)
                local name; name=$(safe_read "Имя/ID контейнера для логов: " "")
                if [[ -n "$name" ]]; then
                    echo "--- ЛОГИ $name (CTRL+C, чтобы выйти) ---"
                    docker logs -f "$name" || printf_error "Контейнер '$name' не найден."
                fi
                ;;
            3)
                local name; name=$(safe_read "Имя/ID контейнера: " "")
                if [[ -z "$name" ]]; then continue; fi
                echo "   1) Старт  2) Стоп  3) Рестарт"
                local act; act=$(safe_read "Действие: " "1")
                case "$act" in
                    1) docker start "$name" || printf_error "Не удалось стартануть '$name'" ;;
                    2) docker stop "$name" || printf_error "Не удалось остановить '$name'" ;;
                    3) docker restart "$name" || printf_error "Не удалось перезапустить '$name'" ;;
                    *) printf_error "Нет такого действия. Смори, что жмёшь." ;;
                esac
                wait_for_enter
                ;;
            4)
                local name; name=$(safe_read "Имя/ID контейнера для удаления: " "")
                if [[ -z "$name" ]]; then continue; fi
                read -p "Точно снести '$name'? (y/n): " c
                if [[ "$c" == "y" ]]; then
                    docker stop "$name" 2>/dev/null || true
                    docker rm "$name" || printf_error "Не удалось удалить '$name'"
                fi
                wait_for_enter
                ;;
            [bB]) break ;;
            *) printf_error "Нет такого пункта. Внимательнее, босс."; sleep 1 ;;
        esac
    done
}

_show_docker_networks_menu() {
    while true; do
        clear
        echo "--- DOCKER: СЕТИ ---"
        echo "----------------------------------------"
        echo "   1. 🌐 Список сетей (docker network ls)"
        echo "   2. 🔍 Информация по сети (docker network inspect)"
        echo "   b. Назад"
        echo "----------------------------------------"
        local choice; read -r -p "Твой выбор: " choice || continue
        case "$choice" in
            1) echo; docker network ls; wait_for_enter ;;
            2)
                local net; net=$(safe_read "Имя/ID сети: " "")
                [[ -n "$net" ]] && docker network inspect "$net" || printf_error "Сеть '$net' не найдена."
                wait_for_enter
                ;;
            [bB]) break ;;
            *) printf_error "Нет такого пункта. Внимательнее, босс."; sleep 1 ;;
        esac
    done
}

_show_docker_volumes_menu() {
    while true; do
        clear
        echo "--- DOCKER: ТОМA ---"
        echo "----------------------------------------"
        echo "   1. 📦 Список томов (docker volume ls)"
        echo "   2. 🔍 Информация по тому (docker volume inspect)"
        echo "   3. 🗑️ Удалить том"
        echo "   b. Назад"
        echo "----------------------------------------"
        local choice; read -r -p "Твой выбор: " choice || continue
        case "$choice" in
            1) echo; docker volume ls; wait_for_enter ;;
            2)
                local vol; vol=$(safe_read "Имя тома: " "")
                [[ -n "$vol" ]] && docker volume inspect "$vol" || printf_error "Том '$vol' не найден."
                wait_for_enter
                ;;
            3)
                local vol; vol=$(safe_read "Имя тома для удаления: " "")
                if [[ -z "$vol" ]]; then continue; fi
                read -p "Точно снести том '$vol'? (y/n): " c
                if [[ "$c" == "y" ]]; then
                    docker volume rm "$vol" || printf_error "Не удалось удалить том '$vol'"
                fi
                wait_for_enter
                ;;
            [bB]) break ;;
            *) printf_error "Нет такого пункта. Внимательнее, босс."; sleep 1 ;;
        esac
    done
}

show_docker_menu() {
    while true; do
        clear
        printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_CYAN}║                 🐳 УПРАВЛЕНИЕ DOCKER                        ║${C_RESET}"
        printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
        echo ""
        echo "   [1] 🧹 Очистка мусора (образы, кэш, тома)"
        echo "   [2] 📦 Контейнеры (список, логи, управление)"
        echo "   [3] 🌐 Сети Docker"
        echo "   [4] 💽 Томa Docker"
        echo ""
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"
        local choice; choice=$(safe_read "Твой выбор: " "")
        case "$choice" in
            1) _show_docker_cleanup_menu ;;
            2) _show_docker_containers_menu ;;
            3) _show_docker_networks_menu ;;
            4) _show_docker_volumes_menu ;;
            [bB]) break ;;
            *) printf_error "Нет такого пункта. Смотри в меню, босс."; sleep 1 ;;
        esac
    done
}

# Главное меню модуля диагностики
show_diagnostics_menu() {
    while true; do
        # Перед показом логов обновляем картину мира по Remnawave/боту
        if command -v run_module &>/dev/null; then
            run_module state_scanner scan_remnawave_state
        fi

        clear
        printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_CYAN}║              📜 БЫСТРЫЕ ЛОГИ (ЧЕКНУТЬ, ЧЁ ТАМ)               ║${C_RESET}"
        printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
        echo ""
        echo "   [1] 📒 Журнал самого «Решалы»"
        
        # Динамически добавляем кнопки в зависимости от того, что найдено сканером
        if [[ "$SERVER_TYPE" == *"Панель"* ]]; then
             echo "   [2] 📊 Логи Панели (Backend)"
        fi
        if [[ "$SERVER_TYPE" == *"Нода"* ]]; then
             echo "   [3] 📡 Логи Ноды (Xray)"
        fi
        if [ "${BOT_DETECTED:-0}" -eq 1 ]; then 
            echo "   [4] 🤖 Логи Бота (Bedalaga)"
        fi
        
        echo ""
        echo "   [b] 🔙 Назад в главное меню"
        echo "------------------------------------------------------"
        
        local choice; choice=$(safe_read "Какой лог курим?: " "")
        case "$choice" in
            1)
                view_logs_realtime "$LOGFILE" "Решалы"
                ;;
            2)
                if [[ "$SERVER_TYPE" == *"Панель"* ]]; then
                    view_docker_logs "$PANEL_NODE_PATH" "Панели"
                else
                    printf_error "Панели нет, логов нет."
                fi
                ;;
            3)
                if [[ "$SERVER_TYPE" == *"Нода"* ]]; then
                    view_docker_logs "$PANEL_NODE_PATH" "Ноды"
                else
                    printf_error "Ноды нет, логов нет."
                fi
                ;;
            4)
                if [ "${BOT_DETECTED:-0}" -eq 1 ]; then
                    view_docker_logs "${BOT_PATH}/docker-compose.yml" "Бота"
                else
                    printf_error "Бота нет, ты ошибся."
                fi
                ;;
            [bB])
                break
                ;;
            *) ;;
        esac
    done
}
