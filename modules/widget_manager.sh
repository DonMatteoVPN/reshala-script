#!/bin/bash
# ============================================================ #
# ==             МОДУЛЬ УПРАВЛЕНИЯ ВИДЖЕТАМИ                == #
# ============================================================ #
#
# Включает и выключает виджеты для дашборда и даёт утилиту для
# быстрой очистки их кеша.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

_clear_widget_cache() {
    local cache_dir="/tmp/reshala_widgets_cache"
    if [ -d "$cache_dir" ]; then
        rm -rf "${cache_dir%/}/"* 2>/dev/null || true
        printf_ok "Кеш виджетов очищен. При следующем открытии дашборда данные обновятся."
    else
        printf_warning "Кеш виджетов пока не создан — очищать нечего."
    fi
    sleep 1
}

show_widgets_menu() {
    local WIDGETS_DIR="${SCRIPT_DIR}/plugins/dashboard_widgets"

    while true; do
        clear
        menu_header "🔧 УПРАВЛЕНИЕ ВИДЖЕТАМИ ДАШБОРДА"
        echo ""
        echo "   Здесь ты можешь включать/выключать отдельные виджеты"
        echo "   и при необходимости сбросить их кеш для жёсткого обновления."
        echo ""

        # Получаем список включенных виджетов из конфига
        local enabled_widgets; enabled_widgets=$(get_config_var "ENABLED_WIDGETS")
        
        # Убираем пробелы/переводы строк из списка включённых виджетов
        enabled_widgets=$(echo "$enabled_widgets" | tr -d ' \t\r')

        # Сканируем папку с плагинами
        local available_widgets=()
        local i=1
        if [ -d "$WIDGETS_DIR" ]; then
            for widget_file in "$WIDGETS_DIR"/*.sh; do
                if [ -f "$widget_file" ]; then
                    local widget_name; widget_name=$(basename "$widget_file" | tr -d ' \t\r')
                    available_widgets[$i]=$widget_name

                    # Читаем человекочитаемое имя из комментария # TITLE:
                    local widget_title
                    widget_title=$(grep -m1 '^# TITLE:' "$widget_file" 2>/dev/null | sed 's/^# TITLE:[[:space:]]*//')
                    if [[ -z "$widget_title" ]]; then
                        widget_title="$widget_name"
                    fi
                    
                    # Проверяем, включен ли виджет
                    local status; local status_color
                    if [[ ",$enabled_widgets," == *",$widget_name,"* ]]; then
                        status="ВКЛЮЧЕН"
                        status_color="${C_GREEN}"
                    else
                        status="ВЫКЛЮЧЕН"
                        status_color="${C_RED}"
                    fi
                    
                    printf "   [%d] %b%-10s%b - %s\\n" "$i" "$status_color" "[$status]" "${C_RESET}" "$widget_title"
                    ((i++))
                fi
            done
        fi
        
        if [ ${#available_widgets[@]} -eq 0 ]; then
            printf_warning "Не найдено ни одного виджета в папке ${WIDGETS_DIR}"
        fi

        echo "------------------------------------------------------"
        echo "   [c] 🧹 Очистить кеш виджетов (обновить данные дашборда)"
        echo "   [b] 🔙 Назад в главное меню"
        echo ""
        
        local choice; choice=$(safe_read "Введи номер виджета, чтобы переключить (Вкл/Выкл), или [c] для очистки кеша: " "")
        
        if [[ "$choice" == "b" || "$choice" == "B" ]]; then
            break
        fi
        if [[ "$choice" == "c" || "$choice" == "C" ]]; then
            _clear_widget_cache
            continue
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ -n "${available_widgets[$choice]:-}" ]; then
            local selected_widget="${available_widgets[$choice]}"
            selected_widget=$(echo "$selected_widget" | tr -d ' \t\r')
            
            # Логика переключения
            if [[ ",$enabled_widgets," == *",$selected_widget,"* ]]; then
                # --- ВЫКЛЮЧАЕМ ---
                # Удаляем из списка
                enabled_widgets=$(echo ",$enabled_widgets," | sed "s|,$selected_widget,|,|g" | sed 's/^,//;s/,$//')
                printf_ok "Виджет '$selected_widget' выключен."
            else
                # --- ВКЛЮЧАЕМ ---
                # Добавляем в список
                if [ -z "$enabled_widgets" ]; then
                    enabled_widgets="$selected_widget"
                else
                    enabled_widgets="$enabled_widgets,$selected_widget"
                fi
                printf_ok "Виджет '$selected_widget' включен."
            fi
            
            # Сохраняем новый список в конфиг
            set_config_var "ENABLED_WIDGETS" "$enabled_widgets"
            sleep 1
        fi
    done
}