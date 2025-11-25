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

# --- HTTP API хелперы ----------------------------------------

_remna_api_request() {
    local method="$1"
    local url="$2"
    local token="${3:-}"
    local data="${4:-}"

    local args=(-s -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "X-Remnawave-Client-Type: reshala")

    if [[ -n "$token" ]]; then
        args+=( -H "Authorization: Bearer $token" )
    fi
    if [[ -n "$data" ]]; then
        args+=( -d "$data" )
    fi

    curl "${args[@]}"
}

_remna_api_register_superadmin() {
    local domain_url="$1"   # host:port, без схемы
    local username="$2"
    local password="$3"

    local body
    body=$(jq -n --arg u "$username" --arg p "$password" '{username:$u,password:$p}') || return 1

    local resp
    resp=$(_remna_api_request "POST" "http://$domain_url/api/auth/register" "" "$body") || true

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

    local resp
    resp=$(_remna_api_request "GET" "http://$domain_url/api/system/tools/x25519/generate" "$token") || true
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
    resp=$(_remna_api_request "POST" "http://$domain_url/api/config-profiles" "$token" "$body") || true
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
    resp=$(_remna_api_request "POST" "http://$domain_url/api/nodes" "$token" "$body") || true
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
    resp=$(_remna_api_request "POST" "http://$domain_url/api/hosts" "$token" "$body") || true
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

    local resp
    resp=$(_remna_api_request "GET" "http://$domain_url/api/internal-squads" "$token") || true
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

    local resp
    resp=$(_remna_api_request "GET" "http://$domain_url/api/internal-squads" "$token") || true
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

    local cookies_random1 cookies_random2 metrics_user metrics_pass
    cookies_random1=$(_remna_generate_user)
    cookies_random2=$(_remna_generate_user)
    metrics_user=$(_remna_generate_user)
    metrics_pass=$(_remna_generate_user)

    local jwt_auth jwt_api
    jwt_auth=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
    jwt_api=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)

    cat > /opt/remnawave/.env <<EOL
### APP ###
APP_PORT=3000
METRICS_PORT=3001

### API ###
API_INSTANCES=1

### DATABASE ###
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### REDIS ###
REDIS_HOST=remnawave-redis
REDIS_PORT=6379

### JWT ###
JWT_AUTH_SECRET=$jwt_auth
JWT_API_TOKENS_SECRET=$jwt_api
JWT_AUTH_LIFETIME=168

### TELEGRAM NOTIFICATIONS ###
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
TELEGRAM_NOTIFY_USERS_CHAT_ID=change_me
TELEGRAM_NOTIFY_NODES_CHAT_ID=change_me
TELEGRAM_NOTIFY_CRM_CHAT_ID=change_me

### FRONT_END ###
FRONT_END_DOMAIN=$panel_domain

### SUBSCRIPTION PUBLIC DOMAIN ###
SUB_PUBLIC_DOMAIN=$sub_domain

### SWAGGER ###
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=false

### PROMETHEUS ###
METRICS_USER=$metrics_user
METRICS_PASS=$metrics_pass

### WEBHOOK ###
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://webhook.site/placeholder
WEBHOOK_SECRET_HEADER=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)

### HWID DEVICE DETECTION AND LIMITATION ###
HWID_DEVICE_LIMIT_ENABLED=false
HWID_FALLBACK_DEVICE_LIMIT=5
HWID_MAX_DEVICES_ANNOUNCE="You have reached the maximum number of devices for your subscription."

### Bandwidth usage reached notifications
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80]

### Database (для локального postgres-контейнера) ###
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOL

    cat > /opt/remnawave/docker-compose.yml <<EOL
services:
  remnawave-db:
    image: postgres:18
    container_name: 'remnawave-db'
    hostname: remnawave-db
    restart: always
    env_file:
      - .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3000:3000'
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-redis:
    image: valkey/valkey:8.1.4-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    networks:
      - remnawave-network
    volumes:
      - remnawave-redis-data:/data
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /var/www/html:/var/www/html:ro

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - META_TITLE=Remnawave Subscription
      - META_DESCRIPTION=page
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=2222
      # SECRET_KEY будет подставлен позже через API Remnawave
    volumes:
      - /dev/shm:/dev/shm:rw
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/16
    external: false

volumes:
  remnawave-db-data:
    driver: local
    external: false
    name: remnawave-db-data
  remnawave-redis-data:
    driver: local
    external: false
    name: remnawave-redis-data
EOL

    # nginx-конфиг — пока БЕЗ TLS, только HTTP (TLS повесим позже/через Cloudflare)
    cat > /opt/remnawave/nginx.conf <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

server {
    listen 80;
    server_name $panel_domain;

    location / {
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
    }
}

server {
    listen 80;
    server_name $sub_domain;

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
    }
}

server {
    listen 80;
    server_name $selfsteal_domain;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}
EOL

    # Сохраняем пару cookie-рандомов и креды админа в отдельный файлик-подсказку
    cat > /opt/remnawave/INSTALL_INFO <<EOL
PANEL_DOMAIN=$panel_domain
SUB_DOMAIN=$sub_domain
SELFSTEAL_DOMAIN=$selfsteal_domain
SUPERADMIN_USERNAME=$superadmin_username
SUPERADMIN_PASSWORD=$superadmin_password
COOKIES_RANDOM1=$cookies_random1
COOKIES_RANDOM2=$cookies_random2
EOL
}

_remna_install_panel_and_node_wizard() {
    clear
    menu_header "Панель + Нода Remnawave на этот сервак"
    echo
    echo "   Ща будем поднимать Remnawave панель и ноду на этот бокс."
    echo "   С тебя — домены и логин админа, всё остальное я дожму сам."
    echo

    local PANEL_DOMAIN SUB_DOMAIN SELFSTEAL_DOMAIN SUPERADMIN_USERNAME

    PANEL_DOMAIN=$(safe_read "Домен панели (типа panel.example.com): " "")
    SUB_DOMAIN=$(safe_read "Домен подписки (типа sub.example.com): " "")
    SELFSTEAL_DOMAIN=$(safe_read "Selfsteal домен ноды (типа node.example.com): " "")
    SUPERADMIN_USERNAME=$(safe_read "Логин суперадмина панели: " "boss")

    if [[ -z "$PANEL_DOMAIN" || -z "$SUB_DOMAIN" || -z "$SELFSTEAL_DOMAIN" ]]; then
        err "Без доменов никуда. Заполни всё и приходи ещё раз."
        return 1
    fi

    if [[ "$PANEL_DOMAIN" == "$SUB_DOMAIN" || "$PANEL_DOMAIN" == "$SELFSTEAL_DOMAIN" || "$SUB_DOMAIN" == "$SELFSTEAL_DOMAIN" ]]; then
        err "Домены панели, подписки и ноды должны быть разными. Не мешай кашу." 
        return 1
    fi

    info "Готовлю рабочую директорию /opt/remnawave..."
    if ! _remna_prepare_dir; then
        err "Не смог подготовить /opt/remnawave. Смотри логи."
        return 1
    fi

    local SUPERADMIN_PASSWORD
    SUPERADMIN_PASSWORD=$(_remna_generate_password)

    log "Remnawave: установка панель+нода; panel=$PANEL_DOMAIN sub=$SUB_DOMAIN selfsteal=$SELFSTEAL_DOMAIN user=$SUPERADMIN_USERNAME"

    info "Пишу .env, docker-compose.yml и nginx.conf под твои домены..."
    _remna_write_env_and_compose "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD" || {
        err "Не смог собрать файлы окружения Remnawave."
        return 1
    }

    info "Стартую Docker-композ Remnawave (это займет пару минут)..."
    (
        cd /opt/remnawave && run_cmd docker compose up -d
    ) || {
        err "docker compose up -d для Remnawave отработал с ошибкой. Смотри docker-логи."
        return 1
    }

    info "Жду, пока панель поднимется и начнет отвечать по HTTP..."
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
        err "Панель так и не ответила на /api/auth/status."
        return 1
    fi

    info "Регистрирую суперадмина в панели..."
    local token
    token=$(_remna_api_register_superadmin "$domain_url" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD") || return 1

    info "Генерю x25519-ключи для первого конфига..."
    local private_key
    private_key=$(_remna_api_generate_x25519 "$domain_url" "$token") || return 1

    info "Создаю базовый config-profile под selfsteal-домен ноды..."
    local cfg inbound
    read -r cfg inbound < <(_remna_api_create_config_profile "$domain_url" "$token" "StealConfig" "$SELFSTEAL_DOMAIN" "$private_key") || return 1

    info "Регистрирую первую ноду и host в панели..."
    _remna_api_create_node "$domain_url" "$token" "$cfg" "$inbound" "$SELFSTEAL_DOMAIN" "StealNode" || return 1
    _remna_api_create_host "$domain_url" "$token" "$inbound" "$SELFSTEAL_DOMAIN" "$cfg" "StealHost" || return 1

    info "Прописываю inbound ноды в дефолтный squad..."
    local squad
    squad=$(_remna_api_get_default_squad_uuid "$domain_url" "$token") || return 1
    _remna_api_add_inbound_to_squad "$domain_url" "$token" "$squad" "$inbound" || return 1

    ok "Панель и нода Remnawave подняты и зарегистрированы."
    echo
    info "Адрес панели: https://$PANEL_DOMAIN (пока без TLS, ставь Cloudflare/прокси или добавим cert'ы позже)"
    info "Логин суперадмина: $SUPERADMIN_USERNAME"
    info "Пароль суперадмина: $SUPERADMIN_PASSWORD"
    echo
    wait_for_enter
}

# === ГЛАВНОЕ МЕНЮ МОДУЛЯ =====================================

show_remnawave_panel_node_menu() {
    while true; do
        clear
        menu_header "Remnawave: Панель + Нода (локальная установка)"
        echo
        echo "   Тут поднимаем Remnawave панель и ноду НА ЭТОМ сервере."
        echo "   Панель сразу настроим через API, ноде выпишем ключи."
        echo
        echo "   [1] Установить панель + ноду на этот сервак"
        echo "   [2] (WIP) Управление уже установленной панелью/нодой"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "")

        case "$choice" in
            1) _remna_install_panel_and_node_wizard ;;
            2) warn "Меню управления панелью/нодой ещё в разработке."; sleep 2 ;;
            [bB]) break ;;
            *) err "Нет такого пункта, смотри внимательнее, босс." ;;
        esac
    done
}
