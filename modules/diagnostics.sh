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

show_diagnostics_menu() {
    while true; do
        clear
        printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_CYAN}║              📜 ДИАГНОСТИКА И ЛОГИ (ЧЕК-АП)                 ║${C_RESET}"
        printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
        echo ""; 
        echo "   [1] 📜 Посмотреть журнал «Решалы»"; 
        echo "   [2] 🐳 Управление Docker (Очистка)"; 
        echo ""; 
        echo "   [b] 🔙 Назад в главное меню"; 
        echo "------------------------------------------------------"
        local choice; choice=$(safe_read "Твой выбор: " "")
        case "$choice" in
            1) view_logs_realtime "$LOGFILE" "Решалы" ;;
            2) _show_docker_cleanup_menu ;;
            [bB]) break ;;
        esac
    done
}