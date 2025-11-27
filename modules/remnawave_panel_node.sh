#!/bin/bash
# ============================================================ #
# ==         МОДУЛЬ УСТАНОВКИ REMNAWAVE ПАНЕЛИ+НОДЫ         == #
# ============================================================ #
#
# Этот модуль ставит Remnawave панель и ноду на ЭТОТ сервер,
# автоматически настраивает панель через HTTP API и создаёт
# первую ноду в панели. Построен по гайду GUIDE_MODULES.md.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Подключаем общий модуль работы с доменами и сертификатами Remnawave
# (remna_extract_domain, remna_check_domain, remna_handle_certificates и др.).
if [ -f "${SCRIPT_DIR}/modules/remnawave_certs.sh" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/modules/remnawave_certs.sh"
fi

# Отдельный модуль с шаблонами .env для разных сценариев Remnawave
if [ -f "${SCRIPT_DIR}/modules/remnawave_env.sh" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/modules/remnawave_env.sh"
fi

# Шаблоны docker-compose стека для различных режимов
if [ -f "${SCRIPT_DIR}/modules/remnawave_docker.sh" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/modules/remnawave_docker.sh"
fi

# Шаблоны nginx-конфигов для разных сценариев Remnawave
if [ -f "${SCRIPT_DIR}/modules/remnawave_nginx.sh" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/modules/remnawave_nginx.sh"
fi

# === ВНУТРЕННИЕ ХЕЛПЕРЫ (будут дополняться) ==================

# --- генерация служебных значений -----------------------------

_remna_generate_password() {
    # Генерация сложного пароля для суперадмина панели
    local length=24
    local upper='A-Z'
    local lower='a-z'
    local digit='0-9'
    local special='!@#%^&*()_+'
    local all='A-Za-z0-9!@#%^&*()_+'
    local pwd=""

    pwd+=$(head /dev/urandom | tr -dc "$upper"   | head -c 1)
    pwd+=$(head /dev/urandom | tr -dc "$lower"   | head -c 1)
    pwd+=$(head /dev/urandom | tr -dc "$digit"   | head -c 1)
    pwd+=$(head /dev/urandom | tr -dc "$special" | head -c 3)
    pwd+=$(head /dev/urandom | tr -dc "$all"     | head -c $((length-6)))

    echo "$pwd" | fold -w1 | shuf | tr -d '\n'
}

_remna_generate_user() {
    # Короткий псевдоним/юзернейм для всяких METRICS_USER, cookies и т.п.
    tr -dc 'a-zA-Z' </dev/urandom | head -c 8
}

_remna_prepare_dir() {
    # Готовим /opt/remnawave
    run_cmd mkdir -p /opt/remnawave || return 1
    return 0
}

# Проверки доменов теперь живут в общем модуле remnawave_certs.sh
# (remna_check_domain). Здесь отдельная обёртка не нужна.

# --- HTTP API хелперы ----------------------------------------

# Нормализация base URL панели: принимаем host:port или http(s)://...
_remna_api_normalize_base_url() {
    local base="$1"
    if [[ -z "$base" ]]; then
        base="127.0.0.1:3000"
    fi
    if [[ "$base" != http://* && "$base" != https://* ]]; then
        base="http://$base"
    fi
    echo "${base%/}"
}

_remna_api_request() {
    local method="$1"
    local url="$2"      # Полный URL: http(s)://host[:port]/path
    local token="${3:-}"
    local data="${4:-}"

    # Имитация запроса через reverse‑proxy c HTTPS (как делает фронтовой nginx)
    local forwarded_for="$url"
    forwarded_for="${forwarded_for#http://}"
    forwarded_for="${forwarded_for#https://}"

    local args=(
        -s -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "X-Remnawave-Client-Type: reshala" \
        -H "X-Forwarded-For: $forwarded_for" \
        -H "X-Forwarded-Proto: https"
    )

    if [[ -n "$token" ]]; then
        args+=( -H "Authorization: Bearer $token" )
    fi
    if [[ -n "$data" ]]; then
        args+=( -d "$data" )
    fi

    curl "${args[@]}"
}

_remna_api_register_superadmin() {
    local domain_url="$1"   # host:port или base URL
    local username="$2"
    local password="$3"

    local body
    body=$(jq -n --arg u "$username" --arg p "$password" '{username:$u,password:$p}') || return 1

    local base_url
    base_url=$(_remna_api_normalize_base_url "$domain_url")

    local resp
    resp=$(_remna_api_request "POST" "$base_url/api/auth/register" "" "$body") || true

    if [[ -z "$resp" ]]; then
        err "Панель не ответила на /api/auth/register. Смотри docker-логи Remnawave."
        return 1
    fi

    local token
    token=$(echo "$resp" | jq -r '.response.accessToken // .accessToken // empty') || true
    if [[ -z "$token" || "$token" == "null" ]]; then
        err "Не смог вытащить accessToken из ответа регистрации панели."
        log "Remnawave register response: $resp"
        return 1
    fi

    echo "$token"
}

_remna_api_generate_x25519() {
    local domain_url="$1"
    local token="$2"

    local base_url
    base_url=$(_remna_api_normalize_base_url "$domain_url")

    local resp
    resp=$(_remna_api_request "GET" "$base_url/api/system/tools/x25519/generate" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Панель не ответила на генерацию x25519-ключей."
        return 1
    fi

    local priv
    priv=$(echo "$resp" | jq -r '.response.keypairs[0].privateKey // empty') || true
    if [[ -z "$priv" || "$priv" == "null" ]]; then
        err "Не смог вытащить privateKey из ответа x25519."
        log "x25519 response: $resp"
        return 1
    fi

    echo "$priv"
}

_remna_api_create_config_profile() {
    local domain_url="$1"
    local token="$2"
    local name="$3"
    local domain="$4"
    local private_key="$5"
    local inbound_tag="${6:-Steal}"

    local base_url
    base_url=$(_remna_api_normalize_base_url "$domain_url")

    local short_id
    short_id=$(openssl rand -hex 8 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 16)

    local body
    body=$(jq -n \
        --arg name "$name" \
        --arg domain "$domain" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --arg inbound_tag "$inbound_tag" '{
            name: $name,
            config: {
                log: { loglevel: "warning" },
                dns: {
                    queryStrategy: "UseIPv4",
                    servers: [{ address: "https://dns.google/dns-query", skipFallback: false }]
                },
                inbounds: [{
                    tag: $inbound_tag,
                    port: 443,
                    protocol: "vless",
                    settings: { clients: [], decryption: "none" },
                    sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
                    streamSettings: {
                        network: "tcp",
                        security: "reality",
                        realitySettings: {
                            show: false,
                            xver: 1,
                            dest: "/dev/shm/nginx.sock",
                            spiderX: "",
                            shortIds: [$short_id],
                            privateKey: $private_key,
                            serverNames: [$domain]
                        }
                    }
                }],
                outbounds: [
                    { tag: "DIRECT", protocol: "freedom" },
                    { tag: "BLOCK", protocol: "blackhole" }
                ],
                routing: {
                    rules: [
                        { ip: ["geoip:private"], type: "field", outboundTag: "BLOCK" },
                        { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" }
                    ]
                }
            }
        }') || return 1

    local resp
    resp=$(_remna_api_request "POST" "$base_url/api/config-profiles" "$token" "$body") || true
    if [[ -z "$resp" ]]; then
        err "Не получил ответ от /api/config-profiles при создании профиля."
        return 1
    fi

    local cfg inbound
    cfg=$(echo "$resp" | jq -r '.response.uuid // empty') || true
    inbound=$(echo "$resp" | jq -r '.response.inbounds[0].uuid // empty') || true

    if [[ -z "$cfg" || -z "$inbound" || "$cfg" == "null" || "$inbound" == "null" ]]; then
        err "API вернуло кривые UUID для config profile/inbound."
        log "create_config_profile response: $resp"
        return 1
    fi

    echo "$cfg $inbound"
}

_remna_api_create_node() {
    local domain_url="$1"
    local token="$2"
    local config_profile_uuid="$3"
    local inbound_uuid="$4"
    local node_address="${5:-172.30.0.1}"
    local node_name="${6:-Steal}"

    local base_url
    base_url=$(_remna_api_normalize_base_url "$domain_url")

    local body
    body=$(jq -n \
        --arg cfg "$config_profile_uuid" \
        --arg inb "$inbound_uuid" \
        --arg addr "$node_address" \
        --arg name "$node_name" '{
            name: $name,
            address: $addr,
            port: 2222,
            configProfile: {
                activeConfigProfileUuid: $cfg,
                activeInbounds: [$inb]
            },
            isTrafficTrackingActive: false,
            trafficLimitBytes: 0,
            notifyPercent: 0,
            trafficResetDay: 31,
            excludedInbounds: [],
            countryCode: "XX",
            consumptionMultiplier: 1.0
        }') || return 1

    local resp
    resp=$(_remna_api_request "POST" "$base_url/api/nodes" "$token" "$body") || true
    if [[ -z "$resp" ]]; then
        err "Пустой ответ от /api/nodes при создании ноды."
        return 1
    fi

    if ! echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err "Не удалось создать ноду в панели (нет response.uuid)."
        log "create_node response: $resp"
        return 1
    fi

    return 0
}

_remna_api_create_host() {
    local domain_url="$1"
    local token="$2"
    local inbound_uuid="$3"
    local address="$4"
    local config_uuid="$5"
    local remark="${6:-Steal}"

    local base_url
    base_url=$(_remna_api_normalize_base_url "$domain_url")

    local body
    body=$(jq -n \
        --arg cfg "$config_uuid" \
        --arg inb "$inbound_uuid" \
        --arg addr "$address" \
        --arg r "$remark" '{
            inbound: {
                configProfileUuid: $cfg,
                configProfileInboundUuid: $inb
            },
            remark: $r,
            address: $addr,
            port: 443,
            path: "",
            sni: $addr,
            host: "",
            alpn: null,
            fingerprint: "chrome",
            allowInsecure: false,
            isDisabled: false,
            securityLayer: "DEFAULT"
        }') || return 1

    local resp
    resp=$(_remna_api_request "POST" "$base_url/api/hosts" "$token" "$body") || true
    if [[ -z "$resp" ]]; then
        err "Пустой ответ от /api/hosts при создании host'а."
        return 1
    fi

    if ! echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err "Не удалось создать host в панели (нет response.uuid)."
        log "create_host response: $resp"
        return 1
    fi

    return 0
}

_remna_api_get_default_squad_uuid() {
    local domain_url="$1"
    local token="$2"

    local base_url
    base_url=$(_remna_api_normalize_base_url "$domain_url")

    local resp
    resp=$(_remna_api_request "GET" "$base_url/api/internal-squads" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Пустой ответ от /api/internal-squads."
        return 1
    fi

    local uuid
    uuid=$(echo "$resp" | jq -r '.response.internalSquads[0].uuid // empty') || true
    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        err "Не нашёл ни одного internal squad в панели."
        log "internal-squads response: $resp"
        return 1
    fi

    echo "$uuid"
}

_remna_api_add_inbound_to_squad() {
    local domain_url="$1"
    local token="$2"
    local squad_uuid="$3"
    local inbound_uuid="$4"

    local base_url
    base_url=$(_remna_api_normalize_base_url "$domain_url")

    local resp
    resp=$(_remna_api_request "GET" "$base_url/api/internal-squads" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Не удалось перечитать список squadов перед обновлением."
        return 1
    fi

    local existing
    existing=$(echo "$resp" | jq -r --arg uuid "$squad_uuid" '.response.internalSquads[] | select(.uuid == $uuid) | .inbounds[].uuid' 2>/dev/null || true)
    if [[ -z "$existing" ]]; then
        existing="[]"
    else
        existing=$(echo "$existing" | jq -R . | jq -s .)
    fi

    local merged
    merged=$(jq -n --argjson ex "$existing" --arg inb "$inbound_uuid" '$ex + [$inb] | unique')

    local body
    body=$(jq -n --arg uuid "$squad_uuid" --argjson inb "$merged" '{uuid:$uuid,inbounds:$inb}')

    local upd
    upd=$(_remna_api_request "PATCH" "http://$domain_url/api/internal-squads" "$token" "$body") || true
    if [[ -z "$upd" ]] || ! echo "$upd" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err "Не удалось обновить squad (привязать inbound)."
        log "update_squad response: $upd"
        return 1
    fi

    return 0
}

# --- подготовка файлов окружения ------------------------------

_remna_write_env_and_compose() {
    local panel_domain="$1"
    local sub_domain="$2"
    local selfsteal_domain="$3"

    local superadmin_username="$4"
    local superadmin_password="$5"
    local stack_mode="${6:-cookie}"   # cookie | plain (по умолчанию cookie)

    local cookies_random1 cookies_random2 metrics_user metrics_pass
    cookies_random1=$(_remna_generate_user)
    cookies_random2=$(_remna_generate_user)
    metrics_user=$(_remna_generate_user)
    metrics_pass=$(_remna_generate_user)

    local jwt_auth jwt_api
    jwt_auth=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
    jwt_api=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)

    # Полноценный .env собираем через отдельный модуль окружения
    remna_env_write_panel_node \
        "/opt/remnawave" \
        "$panel_domain" \
        "$sub_domain" \
        "$selfsteal_domain" \
        "$metrics_user" \
        "$metrics_pass" \
        "$jwt_auth" \
        "$jwt_api" || return 1

    # docker-compose.yml полностью формируем через модуль стека
    remna_docker_write_panel_node "/opt/remnawave" || return 1

    # nginx-конфиг (HTTP-вариант без TLS) формируем через отдельный модуль nginx
    remna_nginx_write_panel_node_http "/opt/remnawave" "$panel_domain" "$sub_domain" "$selfsteal_domain" || return 1

    # Сохраняем пару cookie-рандомов, режим стека и креды админа в отдельный файлик-подсказку
    cat > /opt/remnawave/INSTALL_INFO <<EOL
PANEL_DOMAIN=$panel_domain
SUB_DOMAIN=$sub_domain
SELFSTEAL_DOMAIN=$selfsteal_domain
SUPERADMIN_USERNAME=$superadmin_username
SUPERADMIN_PASSWORD=$superadmin_password
COOKIES_RANDOM1=$cookies_random1
COOKIES_RANDOM2=$cookies_random2
STACK_MODE=$stack_mode
EOL
}

# --- TLS для панели+ноды (ACME HTTP-01, Let's Encrypt) ---------

# Переписываем nginx.conf под HTTPS для панели и страницы подписки,
# selfsteal-домен остаётся на чистом HTTP (маскировка).
_remna_panel_node_write_nginx_tls() {
    local panel_domain="$1"
    local sub_domain="$2"
    local selfsteal_domain="$3"

    # Определяем, из какого каталога брать сертификаты:
    #  - если есть /etc/letsencrypt/live/<домена> — используем его;
    #  - иначе пробуем базовый домен (поддержка wildcard *.base_domain).
    local panel_cert_domain="$panel_domain"
    local sub_cert_domain="$sub_domain"

    if [[ ! -f "/etc/letsencrypt/live/$panel_domain/fullchain.pem" ]]; then
        local base
        base=$(remna_extract_domain "$panel_domain")
        if [[ -n "$base" && -f "/etc/letsencrypt/live/$base/fullchain.pem" ]]; then
            panel_cert_domain="$base"
        fi
    fi

    if [[ ! -f "/etc/letsencrypt/live/$sub_domain/fullchain.pem" ]]; then
        local base2
        base2=$(remna_extract_domain "$sub_domain")
        if [[ -n "$base2" && -f "/etc/letsencrypt/live/$base2/fullchain.pem" ]]; then
            sub_cert_domain="$base2"
        fi
    fi

    # Читаем cookie-рандомы из INSTALL_INFO, чтобы защита панели в nginx
    # совпадала с выданной пользователю ссылкой входа.
    local cookies_random1 cookies_random2
    if [[ -f /opt/remnawave/INSTALL_INFO ]]; then
        cookies_random1=$(grep '^COOKIES_RANDOM1=' /opt/remnawave/INSTALL_INFO | cut -d '=' -f2-)
        cookies_random2=$(grep '^COOKIES_RANDOM2=' /opt/remnawave/INSTALL_INFO | cut -d '=' -f2-)
    fi
    if [[ -z "$cookies_random1" || -z "$cookies_random2" ]]; then
        cookies_random1=$(_remna_generate_user)
        cookies_random2=$(_remna_generate_user)
        {
            sed -i '/^COOKIES_RANDOM1=/d;/^COOKIES_RANDOM2=/d' /opt/remnawave/INSTALL_INFO 2>/dev/null || true
            echo "COOKIES_RANDOM1=$cookies_random1" >> /opt/remnawave/INSTALL_INFO
            echo "COOKIES_RANDOM2=$cookies_random2" >> /opt/remnawave/INSTALL_INFO
        } || true
    fi

    # Определяем режим стека (cookie/plain) из INSTALL_INFO, по умолчанию cookie
    local stack_mode="cookie"
    if [[ -f /opt/remnawave/INSTALL_INFO ]]; then
        local sm
        sm=$(grep '^STACK_MODE=' /opt/remnawave/INSTALL_INFO | cut -d '=' -f2-)
        if [[ "$sm" == "plain" || "$sm" == "cookie" ]]; then
            stack_mode="$sm"
        fi
    fi

    if [[ "$stack_mode" == "plain" ]]; then
        remna_nginx_write_panel_node_tls_plain \
            "/opt/remnawave" \
            "$panel_domain" \
            "$sub_domain" \
            "$selfsteal_domain" \
            "$panel_cert_domain" \
            "$sub_cert_domain" || return 1
    else
        remna_nginx_write_panel_node_tls_cookie \
            "/opt/remnawave" \
            "$panel_domain" \
            "$sub_domain" \
            "$selfsteal_domain" \
            "$panel_cert_domain" \
            "$sub_cert_domain" \
            "$cookies_random1" \
            "$cookies_random2" || return 1
    fi

upstream json {
    server 127.0.0.1:3010;
}

# Управляем апгрейдом соединения (WebSocket и т.п.)
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

# Cookie-защита панели: вход только по спецссылке с "одноразовым ключом".
map \$http_cookie \$auth_cookie {
    default 0;
    "~*${cookies_random1}=${cookies_random2}" 1;
}

map \$arg_${cookies_random1} \$auth_query {
    default 0;
    "${cookies_random2}" 1;
}

map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}

map \$arg_${cookies_random1} \$set_cookie_header {
    "${cookies_random2}" "${cookies_random1}=${cookies_random2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

# Перенаправляем HTTP-запросы панели и страницы подписки на HTTPS
server {
    listen 80;
    server_name $panel_domain;

    return 301 https://$panel_domain\$request_uri;
}

server {
    listen 80;
    server_name $sub_domain;

    return 301 https://$sub_domain\$request_uri;
}

# Selfsteal-домен остаётся HTTP: маскировочный сайт
server {
    listen 80;
    server_name $selfsteal_domain;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    server_name $panel_domain;
    listen 443 ssl http2;

    ssl_certificate "/etc/letsencrypt/live/$panel_cert_domain/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$panel_cert_domain/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/$panel_cert_domain/fullchain.pem";

    add_header Set-Cookie \$set_cookie_header;

    location / {
        error_page 418 = @unauthorized;
        recursive_error_pages on;
        if (\$authorized = 0) {
            return 418;
        }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location @unauthorized {
        root /var/www/html;
        index index.html;
    }
}

server {
    server_name $sub_domain;
    listen 443 ssl http2;

    ssl_certificate "/etc/letsencrypt/live/$sub_cert_domain/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$sub_cert_domain/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/$sub_cert_domain/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 404;
    }
}

# Защита по умолчанию для прочих хостов: TLS-рукопожатие сразу режем
server {
    listen 443 ssl http2 default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL
}

# Старый ACME-флоу (_remna_panel_node_setup_tls_acme/_renew) больше не используется —
# его заменила общая логика из remnawave_certs.sh (remna_handle_certificates +
# remna_fix_letsencrypt_structure). Nginx мы переключаем на HTTPS через
# _remna_panel_node_write_nginx_tls после успешной выдачи сертификатов.

    info "Останавливаю временно nginx-контейнер, чтобы освободить порт 80 для certbot..."
    if ( cd /opt/remnawave && run_cmd docker compose down remnawave-nginx ); then
        :
    else
        warn "Не получилось корректно остановить remnawave-nginx. Продолжаю, но certbot может упасть, если порт 80 занят."
    fi

    if ! run_cmd "${certbot_args[@]}"; then
        err "certbot не смог выписать сертификаты для $panel_domain и $sub_domain."
        if command -v ufw >/dev/null 2>&1; then
            run_cmd ufw delete allow 80/tcp || true
            run_cmd ufw reload || true
        fi
        info "Поднимаю remnawave-nginx обратно..."
        ( cd /opt/remnawave && run_cmd docker compose up -d remnawave-nginx ) || warn "Не удалось заново поднять remnawave-nginx, проверь docker compose вручную."
        return 1
    fi

    if command -v ufw >/dev/null 2>&1; then
        run_cmd ufw delete allow 80/tcp || true
        run_cmd ufw reload || true
    fi

    if [[ ! -d "/etc/letsencrypt/live/$panel_domain" ]]; then
        err "Каталог /etc/letsencrypt/live/$panel_domain не появился после certbot. TLS пропускаем."
        ( cd /opt/remnawave && run_cmd docker compose up -d remnawave-nginx ) || true
        return 1
    fi

    if ! _remna_panel_node_write_nginx_tls "$panel_domain" "$sub_domain" "$selfsteal_domain"; then
        err "Не удалось переписать nginx.conf под HTTPS."
        ( cd /opt/remnawave && run_cmd docker compose up -d remnawave-nginx ) || true
        return 1
    fi

    info "Поднимаю remnawave-nginx уже в HTTPS-конфигурации..."
    if ! ( cd /opt/remnawave && run_cmd docker compose up -d remnawave-nginx ); then
        warn "Не удалось поднять remnawave-nginx после настройки TLS. Проверь docker compose вручную."
    fi

    _remna_panel_node_setup_tls_renew "$panel_domain" || warn "renew_hook/cron для TLS-панели не удалось настроить автоматически, смотри /etc/letsencrypt/renewal/$panel_domain.conf."

    ok "TLS для панели и подписки включён. Теперь можно ходить по https://$panel_domain и https://$sub_domain."
    return 0
}

_remna_install_panel_and_node_wizard() {
    enable_graceful_ctrlc
    clear
    menu_header "Панель + Нода Remnawave на этот сервак"
    echo
    echo "   Режим: поднимаем панель и ноду на один сервер с полной автоматизацией:"
    echo "   1) собираем три домена (панель / подписка / selfsteal-нода);"
    echo "   2) проверяем, что они смотрят на этот сервер и не конфликтуют;"
    echo "   3) поднимаем Docker-стек панели+ноды;"
    echo "   4) через API настраиваем суперадмина, конфиг, ноду и squad;"
    echo "   5) по желанию сразу же выписываем сертификаты Let's Encrypt."
    echo

    local PANEL_DOMAIN SUB_DOMAIN SELFSTEAL_DOMAIN SUPERADMIN_USERNAME

    PANEL_DOMAIN=$(safe_read "Домен ПАНЕЛИ (например panel.example.com): " "")
    SUB_DOMAIN=$(safe_read "Домен ПОДПИСКИ (например sub.example.com): " "")
    SELFSTEAL_DOMAIN=$(safe_read "Selfsteal-домен НОДЫ (например node.example.com): " "")
    SUPERADMIN_USERNAME=$(safe_read "Логин суперадмина панели: " "boss")

    if [[ -z "$PANEL_DOMAIN" || -z "$SUB_DOMAIN" || -z "$SELFSTEAL_DOMAIN" ]]; then
        err "Без всех трёх доменов (панель/подписка/selfsteal) установка невозможна."
        disable_graceful_ctrlc
        return 1
    fi

    if [[ "$PANEL_DOMAIN" == "$SUB_DOMAIN" || "$PANEL_DOMAIN" == "$SELFSTEAL_DOMAIN" || "$SUB_DOMAIN" == "$SELFSTEAL_DOMAIN" ]]; then
        err "Домены панели, подписки и ноды должны быть РАЗНЫМИ."
        disable_graceful_ctrlc
        return 1
    fi

    info "Шаг 1/4. Проверяю, что домены реально смотрят на этот сервак..."
    echo

    local rc

    info "Проверяю домен панели: $PANEL_DOMAIN"
    remna_check_domain "$PANEL_DOMAIN" true true
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка остановлена по твоему решению на проверке домена панели."
        disable_graceful_ctrlc
        return 1
    fi

    info "Проверяю домен подписки: $SUB_DOMAIN"
    remna_check_domain "$SUB_DOMAIN" true true
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка остановлена по твоему решению на проверке домена подписки."
        disable_graceful_ctrlc
        return 1
    fi

    info "Проверяю selfsteal-домен ноды: $SELFSTEAL_DOMAIN (Cloudflare-прокси здесь ЗАПРЕЩЁН)"
    remna_check_domain "$SELFSTEAL_DOMAIN" true false
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка остановлена по твоему решению на проверке selfsteal-домена."
        disable_graceful_ctrlc
        return 1
    fi

    echo
    info "Шаг 2/4. Готовлю рабочую директорию /opt/remnawave и базовые файлы..."
    if ! _remna_prepare_dir; then
        err "Не смог подготовить /opt/remnawave. Смотри логи/права."
        disable_graceful_ctrlc
        return 1
    fi

    local SUPERADMIN_PASSWORD
    SUPERADMIN_PASSWORD=$(_remna_generate_password)

    log "Remnawave: установка панель+нода; panel=$PANEL_DOMAIN sub=$SUB_DOMAIN selfsteal=$SELFSTEAL_DOMAIN user=$SUPERADMIN_USERNAME"

    echo
    info "Как защитить вход в панель?"
    echo "   [1] Секретная ссылка + куки-защита панели (рекомендуется)."
    echo "   [2] Только логин/пароль без дополнительной куки-защиты."
    local STACK_MODE
    local sm_choice
    sm_choice=$(safe_read "Твой выбор [1/2] (по умолчанию 1): " "1")
    if [[ "$sm_choice" == "2" ]]; then
        STACK_MODE="plain"
    else
        STACK_MODE="cookie"
    fi

    info "Пишу .env, docker-compose.yml и nginx.conf под твои домены..."
    _remna_write_env_and_compose "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD" "$STACK_MODE" || {
        err "Не смог собрать файлы окружения Remnawave."
        disable_graceful_ctrlc
        return 1
    }

    info "Шаг 3/4. Стартую Docker-стек Remnawave (панель, БД, Redis, nginx, страница подписки, нода)..."
    (
        cd /opt/remnawave && run_cmd docker compose up -d
    ) || {
        err "docker compose up -d для Remnawave отработал с ошибкой. Проверь docker-логи контейнеров remnawave/*."
        disable_graceful_ctrlc
        return 1
    }

    info "Жду, пока панель поднимется и начнёт отвечать на /api/auth/status..."
    local domain_url="127.0.0.1:3000"
    local tries=30
    local ok_flag=0
    while (( tries-- > 0 )); do
        if curl -s "http://$domain_url/api/auth/status" >/dev/null 2>&1; then
            ok_flag=1
            break
        fi
        sleep 2
    done
    if (( ok_flag == 0 )); then
        err "Панель так и не ответила на /api/auth/status. Проверь docker compose ps и логи контейнера remnawave."
        disable_graceful_ctrlc
        return 1
    fi

    info "Шаг 4/4. Настраиваю панель через HTTP API."
    echo

    info "Регистрирую суперадмина в панели..."
    local token
    token=$(_remna_api_register_superadmin "$domain_url" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD") || {
        disable_graceful_ctrlc
        return 1
    }

    info "Генерю x25519-ключи для первого конфига..."
    local private_key
    private_key=$(_remna_api_generate_x25519 "$domain_url" "$token") || {
        disable_graceful_ctrlc
        return 1
    }

    info "Создаю базовый config-profile под selfsteal-домен ноды ($SELFSTEAL_DOMAIN)..."
    local cfg inbound
    if ! read -r cfg inbound < <(_remna_api_create_config_profile "$domain_url" "$token" "StealConfig" "$SELFSTEAL_DOMAIN" "$private_key"); then
        disable_graceful_ctrlc
        return 1
    fi

    info "Регистрирую первую ноду и host в панели..."
    _remna_api_create_node "$domain_url" "$token" "$cfg" "$inbound" "$SELFSTEAL_DOMAIN" "StealNode" || {
        disable_graceful_ctrlc
        return 1
    }
    _remna_api_create_host "$domain_url" "$token" "$inbound" "$SELFSTEAL_DOMAIN" "$cfg" "StealHost" || {
        disable_graceful_ctrlc
        return 1
    }

    info "Прописываю inbound ноды в дефолтный squad..."
    local squad
    squad=$(_remna_api_get_default_squad_uuid "$domain_url" "$token") || {
        disable_graceful_ctrlc
        return 1
    }
    _remna_api_add_inbound_to_squad "$domain_url" "$token" "$squad" "$inbound" || {
        disable_graceful_ctrlc
        return 1
    }

    ok "Панель и нода Remnawave подняты и зарегистрированы. Базовая рабочая связка готова."
    echo

    info "Дополнительно можем сразу прикрутить HTTPS (TLS-сертификаты Let's Encrypt) для панели и подписки."
    echo

    local enable_tls
    local tls_enabled=false
    enable_tls=$(safe_read "Выписать и подключить сертификаты Let's Encrypt для доменов панели/подписки прямо сейчас? (Y/n): " "Y")
    if [[ "$enable_tls" == "Y" || "$enable_tls" == "y" ]]; then
        # Выпрашиваем или используем уже имеющиеся сертификаты для всех трёх доменов
        if remna_handle_certificates "$PANEL_DOMAIN $SUB_DOMAIN $SELFSTEAL_DOMAIN" 0; then
            info "Переключаю nginx.conf Remnawave на HTTPS-конфигурацию..."
            if _remna_panel_node_write_nginx_tls "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"; then
                info "Перезапускаю только фронтовой nginx-контейнер remnawave-nginx..."
                if ( cd /opt/remnawave && run_cmd docker compose down remnawave-nginx && run_cmd docker compose up -d remnawave-nginx ); then
                    tls_enabled=true
                else
                    warn "Не удалось корректно перезапустить remnawave-nginx. Проверь docker compose вручную."
                fi
            else
                err "Не удалось собрать nginx.conf под HTTPS. Оставляю HTTP-конфигурацию."
            fi
        else
            warn "Сертификаты выписать не удалось. Панель останется на HTTP (можно будет повторить позже)."
        fi
    else
        info "Ок, HTTPS сейчас не трогаем. Можно оставить HTTP и прикрутить TLS позже."
    fi

    echo
    if [[ "$tls_enabled" == true ]]; then
        ok "Панель и подписка уже доступны по HTTPS:"
        info "Панель:      https://$PANEL_DOMAIN"
        info "Подписка:    https://$SUB_DOMAIN"
        info "Selfsteal:   http://$SELFSTEAL_DOMAIN (маскировочный сайт, TLS можно навесить отдельно при желании)"
    else
        info "Панель (HTTP):      http://$PANEL_DOMAIN"
        info "Подписка (HTTP):    http://$SUB_DOMAIN"
        info "Selfsteal (HTTP):   http://$SELFSTEAL_DOMAIN"
        warn "HTTPS для панели/подписки пока не настроен. Можно использовать Cloudflare/прокси или зайти в Remnawave-меню сертификатов и прикрутить TLS позже."
    fi

    echo
    info "Логин суперадмина панели:  $SUPERADMIN_USERNAME"
    info "Пароль суперадмина панели: $SUPERADMIN_PASSWORD"
    echo
    wait_for_enter || true
    disable_graceful_ctrlc
}

# === ГЛАВНОЕ МЕНЮ МОДУЛЯ =====================================

# Ранее этот модуль содержал собственное меню panel+node. Сейчас точка
# входа для Remnawave одна — `remnawave_menu.sh`, а установка
# панель+нода вызывается напрямую через `_remna_install_panel_and_node_wizard`
# из модуля `remnawave_install.sh`. Тут больше нет публичных меню.
