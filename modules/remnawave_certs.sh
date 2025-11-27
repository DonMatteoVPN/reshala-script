#!/bin/bash
# ============================================================ #
# ==        REMNAWAVE: УПРАВЛЕНИЕ СЕРТИФИКАТАМИ (TLS)        == #
# ============================================================ #
# Общий модуль работы с доменами и сертификатами для всех
# сценариев Remnawave. Оформлен в нашем стиле (цвета, ctrl+C и сообщения).
#
# ВАЖНО: модуль предполагает, что уже подключен common.sh
# (функции info/ok/warn/err/run_cmd/safe_read/ask_yes_no и т.д.).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# === БАЗОВЫЕ ХЕЛПЕРЫ ДЛЯ ДОМЕНОВ ===============================

# Получаем базовый домен из поддомена:
#   extract_domain panel.example.com  -> example.com
#   extract_domain example.com        -> example.com
remna_extract_domain() {
    local subdomain="$1"
    echo "$subdomain" | awk -F'.' '{if (NF > 2) {print $(NF-1)"."$NF} else {print $0}}'
}

# Проверка, что домен указывает на нужный IP.
# Возвращаемые коды:
#   0  - всё ок (домен указывает на сервер напрямую или через разрешённый Cloudflare)
#   1  - есть проблема, но пользователь ОСОЗНАННО согласился продолжить
#   2  - пользователь прервал установку
remna_check_domain() {
    local domain="$1"              # проверяемый домен
    local show_warning="${2:-true}" # показывать ли подробные подсказки
    local allow_cf_proxy="${3:-true}" # можно ли домену идти через Cloudflare-прокси

    local domain_ip=""
    local server_ip=""

    # Определяем IP домена (обычный A‑запись)
    if command -v dig >/dev/null 2>&1; then
        domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n 1)
    else
        domain_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')
    fi

    # Внешний IP этого сервера (как его видит интернет)
    server_ip=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || curl -s -4 ipinfo.io/ip)

    # Если не смогли определить один из IP — даём пользователю выбор, что делать дальше
    if [[ -z "$domain_ip" || -z "$server_ip" ]]; then
        if [[ "$show_warning" == true ]]; then
            warn "Не удалось надёжно определить IP домена '$domain' или IP этого сервера."
            info "Сейчас сервер видится как: ${server_ip:-"не удалось определить"}. Домен должен указывать именно сюда."
            local confirm
            confirm=$(safe_read "Продолжить установку, игнорируя эту проверку? (y/N): " "n")
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                return 2
            fi
        fi
        return 1
    fi

    # Готовим список Cloudflare IPv4‑подсетей
    local cf_ranges
    local -a cf_array=()
    cf_ranges=$(curl -s https://www.cloudflare.com/ips-v4 || true)
    if [[ -n "$cf_ranges" ]]; then
        mapfile -t cf_array <<<"$cf_ranges"
    fi

    local ip_in_cloudflare=false
    local a b c d
    local domain_ip_int
    local IFS='.'
    read -r a b c d <<<"$domain_ip"
    domain_ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))

    if (( ${#cf_array[@]} > 0 )); then
        local cidr network mask network_int mask_bits range_size min_ip_int max_ip_int
        for cidr in "${cf_array[@]}"; do
            [[ -z "$cidr" ]] && continue
            network=${cidr%/*}
            mask=${cidr#*/}
            IFS='.' read -r a b c d <<<"$network"
            network_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
            mask_bits=$(( 32 - mask ))
            range_size=$(( 1 << mask_bits ))
            min_ip_int=$network_int
            max_ip_int=$(( network_int + range_size - 1 ))

            if (( domain_ip_int >= min_ip_int && domain_ip_int <= max_ip_int )); then
                ip_in_cloudflare=true
                break
            fi
        done
    fi

    # 1) Домен указывает прямо на IP сервера — идеальный сценарий
    if [[ "$domain_ip" == "$server_ip" ]]; then
        return 0
    fi

    # 2) Домен указывает в Cloudflare
    if [[ "$ip_in_cloudflare" == true ]]; then
        # Для панели/подписки Cloudflare-прокси допустим, для selfsteal — нет
        if [[ "$allow_cf_proxy" == true ]]; then
            return 0
        fi

        if [[ "$show_warning" == true ]]; then
            warn "Домен '$domain' сейчас указывает на IP Cloudflare ($domain_ip), а для этого домена прокси НЕЛЬЗЯ."
            info "Отключи оранжевое облако (режим 'DNS only') для '$domain' в Cloudflare, подожди обновление DNS и запусти ещё раз."
            local confirm
            confirm=$(safe_read "Всё равно продолжить? (y/N): " "n")
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                return 1
            else
                return 2
            fi
        fi
        return 1
    fi

    # 3) Домен указывает на чужой IP, не Cloudflare
    if [[ "$show_warning" == true ]]; then
        warn "Домен '$domain' указывает на IP $domain_ip, а сервер видится как $server_ip. Это не совпадает."
        info "Для нормальной работы Remnawave домен должен указывать ИМЕННО на этот сервер."
        local confirm
        confirm=$(safe_read "Продолжить установку, игнорируя несовпадение IP? (y/N): " "n")
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            return 1
        else
            return 2
        fi
    fi

    return 1
}

# === ХЕЛПЕРЫ ДЛЯ ПРОВЕРКИ/СТРУКТУРЫ LET'S ENCRYPT ==============

# Проверяем, что fullchain.pem содержит wildcard *.<domain>
remna_is_wildcard_cert() {
    local domain="$1"
    local live_dir="/etc/letsencrypt/live/$domain"
    if [[ -f "$live_dir/fullchain.pem" ]] && grep -q "*.$domain" "$live_dir/fullchain.pem" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Исправляем симлинки и renewal-конфиг для конкретного домена
remna_fix_letsencrypt_structure() {
    local cert_domain="$1" # base_domain или конкретный домен
    local live_dir="/etc/letsencrypt/live/$cert_domain"
    local archive_dir="/etc/letsencrypt/archive/$cert_domain"
    local renewal_conf="/etc/letsencrypt/renewal/$cert_domain.conf"

    if [[ ! -d "$archive_dir" ]]; then
        warn "Не найден archive-каталог для $cert_domain ($archive_dir). Пропускаю fix_letsencrypt_structure."
        return 1
    fi

    # Берём последнюю версию файлов в archive
    local latest_index
    latest_index=$(ls "$archive_dir"/cert*.pem 2>/dev/null | sed -E 's/.*cert([0-9]+)\.pem/\1/' | sort -n | tail -n1)
    if [[ -z "$latest_index" ]]; then
        warn "В archive/$cert_domain нет версий сертификатов."
        return 1
    fi

    run_cmd mkdir -p "$live_dir" || return 1

    ln -sf "$archive_dir/cert${latest_index}.pem"      "$live_dir/cert.pem"
    ln -sf "$archive_dir/chain${latest_index}.pem"     "$live_dir/chain.pem"
    ln -sf "$archive_dir/fullchain${latest_index}.pem" "$live_dir/fullchain.pem"
    ln -sf "$archive_dir/privkey${latest_index}.pem"   "$live_dir/privkey.pem"

    # Обновляем renewal-конфиг и прописываем renew_hook под remnawave-nginx
    if [[ -f "$renewal_conf" ]]; then
        run_cmd sed -i \
            -e "s|^cert = .*|cert = $archive_dir/cert${latest_index}.pem|" \
            -e "s|^privkey = .*|privkey = $archive_dir/privkey${latest_index}.pem|" \
            -e "s|^chain = .*|chain = $archive_dir/chain${latest_index}.pem|" \
            -e "s|^fullchain = .*|fullchain = $archive_dir/fullchain${latest_index}.pem|" \
            "$renewal_conf" || true

        local hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'"
        if grep -q '^renew_hook' "$renewal_conf"; then
            run_cmd sed -i "s|^renew_hook.*|$hook|" "$renewal_conf" || true
        else
            echo "$hook" | run_cmd tee -a "$renewal_conf" >/dev/null || true
        fi
    fi

    ok "Структура Let's Encrypt для $cert_domain приведена в порядок."
    return 0
}

# Проверяем, есть ли валидный сертификат для домена или его базового домена.
# Возвращаем 0, если сертификат найден (включая wildcard base_domain), иначе 1.
remna_check_certificates() {
    local domain="$1"

    # Сначала пытаемся найти прямой live-директорию под домен
    local live_dir="/etc/letsencrypt/live/$domain"
    if [[ -d "$live_dir" ]]; then
        # Если файлы существуют, но не symlink-структура — пытаемся починить
        if [[ -f "$live_dir/fullchain.pem" && -f "$live_dir/privkey.pem" ]]; then
            ok "Найден существующий сертификат Let's Encrypt для $domain."
            return 0
        fi
    fi

    # Проверяем wildcard базового домена
    local base_domain
    base_domain=$(remna_extract_domain "$domain")
    if [[ -n "$base_domain" && "$base_domain" != "$domain" ]]; then
        local base_live="/etc/letsencrypt/live/$base_domain"
        if [[ -d "$base_live" ]]; then
            if remna_is_wildcard_cert "$base_domain"; then
                ok "Для $domain найден wildcard сертификат *.${base_domain}."
                return 0
            fi
        fi
    fi

    return 1
}

# Оценка дней до истечения сертификата (для информативных сообщений)
remna_check_cert_expiry() {
    local cert_path="$1" # путь до fullchain.pem
    if [[ ! -f "$cert_path" ]]; then
        echo 0
        return 1
    fi
    local end_date
    end_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | sed 's/^notAfter=//') || {
        echo 0
        return 1
    }
    local end_ts now_ts
    end_ts=$(date -d "$end_date" +%s 2>/dev/null || date -jf '%b %e %T %Y %Z' "$end_date" +%s 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    if [[ "$end_ts" -le 0 ]]; then
        echo 0
        return 1
    fi
    local days=$(( (end_ts - now_ts) / 86400 ))
    [[ $days -lt 0 ]] && days=0
    echo "$days"
    return 0
}

# === ВЫПУСК СЕРТОВ (Cloudflare DNS-01 и ACME HTTP-01) ==========

# Вспомогательная функция для запроса сертификатов.
# cert_method:
#   1 - Cloudflare DNS-01 (wildcard: base_domain + *.base_domain)
#   2 - ACME HTTP-01 (конкретный домен)
remna_get_certificates() {
    local domain="$1"
    local cert_method="$2"
    local email="$3"          # для ACME может быть пустой

    if [[ "$cert_method" == "1" ]]; then
        # Cloudflare DNS-01 — wildcard для base_domain
        local base_domain
        base_domain=$(remna_extract_domain "$domain")
        if [[ -z "$base_domain" ]]; then
            err "Не смог вычислить базовый домен для '$domain'."
            return 1
        fi

        info "Выписываю wildcard-сертификат Let's Encrypt (DNS-01 Cloudflare) для $base_domain и *.$base_domain..."

        local cf_ini="/root/.secrets/certbot/cloudflare.ini"
        run_cmd mkdir -p "$(dirname "$cf_ini")" || return 1

        local cf_email cf_api
        cf_email=$(safe_read "Email Cloudflare (для wildcard сертов): " "")
        cf_api=$(safe_read "API Token Cloudflare (DNS edit для $base_domain): " "")

        if [[ -z "$cf_email" || -z "$cf_api" ]]; then
            err "Cloudflare email или API токен не заданы, не могу выписать wildcard."
            return 1
        fi

        umask 077
        cat > "$cf_ini" <<EOF
# Автогенерируемый файл Решалой. Не делись им ни с кем.
dns_cloudflare_api_token = $cf_api
EOF

        local cmd=(
            certbot certonly --dns-cloudflare \
                --dns-cloudflare-credentials "$cf_ini" \
                --agree-tos --non-interactive \
                -d "$base_domain" -d "*.$base_domain" \
                --key-type ecdsa --elliptic-curve secp384r1
        )
        if [[ -n "$email" ]]; then
            cmd+=(--email "$email")
        else
            cmd+=(--register-unsafely-without-email)
        fi

        if ! run_cmd "${cmd[@]}"; then
            err "Не удалось выписать wildcard-сертификат для $base_domain через Cloudflare DNS-01."
            return 1
        fi

        remna_fix_letsencrypt_structure "$base_domain" || true
        ok "Wildcard-сертификат для $base_domain готов."
        return 0
    elif [[ "$cert_method" == "2" ]]; then
        # ACME HTTP-01 — конкретный домен
        info "Выписываю сертификат Let's Encrypt (HTTP-01) для домена $domain..."

        if ! command -v certbot >/dev/null 2>&1; then
            info "certbot не найден, пробую установить пакет..."
            if ! ensure_package certbot; then
                err "Не удалось установить certbot."
                return 1
            fi
        fi

        local -a cmd=(
            certbot certonly --standalone \
                -d "$domain" \
                --agree-tos --non-interactive \
                --http-01-port 80 \
                --key-type ecdsa --elliptic-curve secp384r1
        )
        if [[ -n "$email" ]]; then
            cmd+=(--email "$email")
        else
            cmd+=(--register-unsafely-without-email)
        fi

        # Временно открываем 80 порт, если есть ufw
        if command -v ufw >/dev/null 2>&1; then
            run_cmd ufw allow 80/tcp comment 'reshala remnawave acme http-01' || true
        fi

        if ! run_cmd "${cmd[@]}"; then
            err "certbot не смог выписать сертификат для $domain."
            if command -v ufw >/dev/null 2>&1; then
                run_cmd ufw delete allow 80/tcp || true
                run_cmd ufw reload || true
            fi
            return 1
        fi

        if command -v ufw >/dev/null 2>&1; then
            run_cmd ufw delete allow 80/tcp || true
            run_cmd ufw reload || true
        fi

        remna_fix_letsencrypt_structure "$domain" || true
        ok "Сертификат для $domain успешно получен."
        return 0
    fi

    err "Неизвестный режим cert_method='$cert_method' в remna_get_certificates."
    return 1
}

# === ГЛАВНЫЙ КООРДИНАТОР СЕРТОВ ДЛЯ УСТАНОВКИ ==================

# domains: список доменов через пробел (панель, саб, selfsteal и т.п.)
# cert_method_hint:
#   0 - спросить пользователя (рекомендуется)
#   1 - форсировать Cloudflare DNS-01 wildcard
#   2 - форсировать ACME HTTP-01 для каждого домена
remna_handle_certificates() {
    local domains_str="$1"
    local cert_method_hint="${2:-0}"

    if [[ -z "$domains_str" ]]; then
        err "remna_handle_certificates вызван без доменов."
        return 1
    fi

    local email=""
    local cert_method=0

    # Определяем, по каким доменам уже есть серты
    local need_any=false
    local d
    for d in $domains_str; do
        if ! remna_check_certificates "$d"; then
            need_any=true
            break
        fi
    done

    if [[ "$need_any" == false ]]; then
        info "Для всех указанных доменов уже найдены действующие сертификаты Let's Encrypt."
    fi

    # Выбор метода — либо по подсказке, либо спросить пользователя
    if [[ "$cert_method_hint" == "1" || "$cert_method_hint" == "2" ]]; then
        cert_method="$cert_method_hint"
    else
        echo
        info "Выбери способ получения сертификатов Let's Encrypt для Remnawave:"
        echo "   1) Cloudflare DNS-01 (wildcard для базовых доменов — panel/sub/selfsteal)"
        echo "   2) Обычный HTTP-01 (каждый домен по отдельности, нужен открытый 80 порт)"
        echo
        local m
        m=$(safe_read "Твой выбор (1/2, Enter чтобы пропустить выпуск и использовать уже имеющиеся сертификаты): " "")
        if [[ "$m" == "1" || "$m" == "2" ]]; then
            cert_method="$m"
        fi
    fi

    if [[ "$cert_method" == "1" ]]; then
        # Сбор уникальных базовых доменов
        local unique_bases=()
        local seen=""
        for d in $domains_str; do
            local base
            base=$(remna_extract_domain "$d")
            [[ -z "$base" ]] && continue
            if [[ " $seen " != *" $base "* ]]; then
                seen+=" $base"
                unique_bases+=("$base")
            fi
        done

        email=$(safe_read "Email для Let's Encrypt (уведомления, можно пустой): " "")

        local b
        for b in "${unique_bases[@]}"; do
            remna_get_certificates "$b" 1 "$email" || return 1
        done

        ok "Wildcard-сертификаты для базовых доменов выписаны или уже были."
    elif [[ "$cert_method" == "2" ]]; then
        email=$(safe_read "Email для Let's Encrypt (уведомления, можно пустой): " "")
        for d in $domains_str; do
            remna_get_certificates "$d" 2 "$email" || return 1
        done
        ok "Сертификаты для всех доменов по HTTP-01 выписаны или уже были."
    else
        info "Метод выдачи сертификатов не выбран — будем использовать только уже существующие сертификаты (если они есть)."
    fi

    # Убедимся, что certbot renew крутится по крону
    if command -v certbot >/dev/null 2>&1; then
        if ! crontab -u root -l 2>/dev/null | grep -q '/usr/bin/certbot renew'; then
            info "Добавляю задачу cron для /usr/bin/certbot renew (каждый день в 05:00)."
            local current
            current=$(crontab -u root -l 2>/dev/null || true)
            printf '%s\n%s\n' "$current" "0 5 * * * /usr/bin/certbot renew --quiet" | crontab -u root - || {
                warn "Не получилось прописать cron для certbot renew. Проверь crontab вручную."
            }
        fi
    fi

    return 0
}

# === ПРОСТОЕ МЕНЮ ДЛЯ РУЧНОЙ ДИАГНОСТИКИ TLS ==================

show_remnawave_certs_menu() {
    enable_graceful_ctrlc
    while true; do
        clear
        menu_header "СЕРТИФИКАТЫ REMNAWAVE (ПАНЕЛЬ/НОДЫ)"
        echo
        echo "   1) Проверить домен (DNS/IP + Cloudflare)">
        echo "   2) Проверить наличие сертификата Let's Encrypt для домена"
        echo "   3) Посмотреть срок действия сертификата (fullchain.pem)"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "b") || break

        case "$choice" in
            1)
                local d
                d=$(ask_non_empty "Введи домен для проверки: " "") || continue
                local allow_cf
                allow_cf=$(safe_read "Разрешить Cloudflare-прокси для этого домена? (Y/n): " "Y")
                local allow_flag=true
                [[ "$allow_cf" == "n" || "$allow_cf" == "N" ]] && allow_flag=false
                remna_check_domain "$d" true "$allow_flag"
                local rc=$?
                echo
                info "Код результата: $rc (0=OK, 1=игнорируем проблему, 2=отмена пользователем)."
                wait_for_enter || true
                ;;
            2)
                local d2
                d2=$(ask_non_empty "Домен для проверки сертификата: " "") || continue
                if remna_check_certificates "$d2"; then
                    ok "Для $d2 найден подходящий сертификат Let's Encrypt (прямой или wildcard)."
                else
                    warn "Для $d2 сертификат Let's Encrypt не найден."
                fi
                wait_for_enter || true
                ;;
            3)
                local path
                path=$(ask_non_empty "Путь до fullchain.pem: " "/etc/letsencrypt/live/example.com/fullchain.pem") || continue
                local days
                days=$(remna_check_cert_expiry "$path") || true
                info "Осталось примерно $days дней до истечения сертификата (если путь указан верно)."
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
