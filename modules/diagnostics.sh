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
