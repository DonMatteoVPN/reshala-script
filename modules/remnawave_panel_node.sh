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

# Проверка, что домен резолвится и указывает на этот сервер (по мотивам donor check_domain)
_remna_check_domain() {
    local domain="$1"
    local show_warning="${2:-true}"
    local allow_cf_proxy="${3:-true}"

    local domain_ip=""
    local server_ip=""

    if command -v dig >/dev/null 2>&1; then
        domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    else
        domain_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')
    fi

    server_ip=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || curl -s -4 ipinfo.io/ip)

    # 0  - всё ок
    # 1  - есть проблема, но пользователь согласился продолжить
    # 2  - пользователь решил прервать установку

    if [[ -z "$domain_ip" || -z "$server_ip" ]]; then
        if [[ "$show_warning" == true ]]; then
            warn "Не смог определить IP домена '$domain' или IP этого сервера."
            info "Проверь DNS: домен должен указывать на текущий сервер. Сейчас сервер видится как: ${server_ip:-\"не удалось определить\"}."
            local confirm
            confirm=$(safe_read "Продолжить установку, игнорируя эту проверку? (y/N): " "n")
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                return 2
            fi
        fi
        return 1
    fi

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

    if [[ "$domain_ip" == "$server_ip" ]]; then
        return 0
    elif [[ "$ip_in_cloudflare" == true ]]; then
        if [[ "$allow_cf_proxy" == true ]]; then
            return 0
        fi

        if [[ "$show_warning" == true ]]; then
            warn "Домен '$domain' сейчас указывает на IP Cloudflare ($domain_ip), для selfsteal-домена так нельзя."
            info "Выключи оранжевое облако (режим 'DNS only') для этого домена в Cloudflare, подожди обновление DNS и запусти установку ещё раз."
            local confirm
            confirm=$(safe_read "Всё равно продолжить установку? (y/N): " "n")
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                return 1
            else
                return 2
            fi
        fi
        return 1
    else
        if [[ "$show_warning" == true ]]; then
            warn "Домен '$domain' указывает на IP $domain_ip, а текущий сервер видится как $server_ip."
            info "Для нормальной работы Remnawave домен должен указывать именно на этот сервер."
            local confirm
            confirm=$(safe_read "Продолжить установку, игнорируя несовпадение IP? (y/N): " "n")
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                return 1
            else
                return 2
            fi
        fi
        return 1
    fi

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
      - /etc/letsencrypt:/etc/letsencrypt:ro

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

# --- TLS для панели+ноды (ACME HTTP-01, Let's Encrypt) ---------

# Переписываем nginx.conf под HTTPS для панели и страницы подписки,
# selfsteal-домен остаётся на чистом HTTP (маскировка).
_remna_panel_node_write_nginx_tls() {
    local panel_domain="$1"
    local sub_domain="$2"
    local selfsteal_domain="$3"

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

    return 301 https://$panel_domain\$request_uri;
}

server {
    listen 80;
    server_name $sub_domain;

    return 301 https://$sub_domain\$request_uri;
}

server {
    listen 80;
    server_name $selfsteal_domain;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    listen 443 ssl http2;
    server_name $panel_domain;

    ssl_certificate     /etc/letsencrypt/live/$panel_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$panel_domain/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

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
    listen 443 ssl http2;
    server_name $sub_domain;

    ssl_certificate     /etc/letsencrypt/live/$panel_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$panel_domain/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

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
EOL
}

# renew_hook + cron для автопродления сертификата панели/подписки
_remna_panel_node_setup_tls_renew() {
    local panel_domain="$1"
    local renewal_conf="/etc/letsencrypt/renewal/$panel_domain.conf"

    if [[ ! -f "$renewal_conf" ]]; then
        warn "Не нашёл $renewal_conf — не на что вешать renew_hook для панели. Пропускаю авто-настройку."
        return 1
    fi

    local hook
    hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'"

    if grep -q '^renew_hook' "$renewal_conf"; then
        run_cmd sed -i "s|^renew_hook.*|$hook|" "$renewal_conf" || return 1
    else
        echo "$hook" | run_cmd tee -a "$renewal_conf" >/dev/null || return 1
    fi

    ok "renew_hook для панели прописан в $renewal_conf."

    # Простейший cron на certbot renew раз в день в 05:00, если ещё нет никакого
    if ! crontab -u root -l 2>/dev/null | grep -q '/usr/bin/certbot renew'; then
        info "Вешаю cron-задачу на certbot renew для сертификатов панели."
        local current
        current=$(crontab -u root -l 2>/dev/null || true)
        printf '%s\n%s\n' "$current" "0 5 * * * /usr/bin/certbot renew --quiet" | run_cmd crontab -u root - || {
            warn "Не получилось прописать cron для certbot renew. Проверь crontab вручную."
        }
    else
        info "cron с certbot renew уже есть — не трогаю его."
    fi

    return 0
}

# Основной ACME-флоу для панели+подписки
_remna_panel_node_setup_tls_acme() {
    local panel_domain="$1"
    local sub_domain="$2"
    local selfsteal_domain="$3"  # пока только для nginx-конфига (HTTP-маскировка)

    info "Сейчас можем включить HTTPS (TLS) для панели и страницы подписки."
    info "TLS = тот самый 'https://' и замочек в браузере: шифрует трафик и убирает красные предупреждения."
    info "Я выпишу бесплатные сертификаты Let's Encrypt для доменов: $panel_domain и $sub_domain."
    echo

    if ! command -v certbot >/dev/null 2>&1; then
        info "Не вижу certbot, попробую аккуратно установить пакет..."
        if ! ensure_package certbot; then
            err "Не смог установить certbot. TLS для панели пока пропускаем."
            return 1
        fi
    fi

    local email
    email=$(safe_read "Email для Let's Encrypt (уведомления о сертификатах, можно пустой): " "")

    local -a certbot_args
    certbot_args=(certbot certonly --standalone -d "$panel_domain" -d "$sub_domain" --agree-tos --non-interactive --http-01-port 80 --key-type ecdsa --elliptic-curve secp384r1)
    if [[ -n "$email" ]]; then
        certbot_args+=(--email "$email")
    else
        certbot_args+=(--register-unsafely-without-email)
    fi

    # Если есть ufw — временно откроем 80 порт под challenge
    if command -v ufw >/dev/null 2>&1; then
        run_cmd ufw allow 80/tcp comment 'reshala remnawave panel acme http-01' || true
    fi

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

    info "Проверяю, что домены реально смотрят на этот сервер..."
    local rc

    _remna_check_domain "$PANEL_DOMAIN" true true
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка прервана по твоему запросу на проверке домена панели."
        return 1
    fi

    _remna_check_domain "$SUB_DOMAIN" true true
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка прервана по твоему запросу на проверке домена подписки."
        return 1
    fi

    _remna_check_domain "$SELFSTEAL_DOMAIN" true false
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка прервана по твоему запросу на проверке selfsteal-домена ноды."
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

    info "Теперь про HTTPS (TLS-сертификат)."
    info "TLS = тот самый 'https://' и замочек в браузере: шифрует трафик и убирает красные предупреждения."
    info "Я могу сейчас выписать бесплатные сертификаты Let's Encrypt для панели и страницы подписки."
    echo

    local enable_tls
    local tls_enabled=false
    enable_tls=$(safe_read "Включить HTTPS (TLS-сертификаты Let's Encrypt) для панели/подписки прямо сейчас? (Y/n): " "Y")
    if [[ "$enable_tls" == "Y" || "$enable_tls" == "y" ]]; then
        if _remna_panel_node_setup_tls_acme "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"; then
            tls_enabled=true
        else
            warn "TLS не удалось настроить автоматически. Оставляем HTTP, можно будет разобраться вручную."
        fi
    else
        info "Ок, HTTPS сейчас не трогаем. Всегда можно будет докрутить сертификаты позже."
    fi

    echo
    if [[ "$tls_enabled" == true ]]; then
        ok "Панель и подписка уже доступны по HTTPS:"
        info "Панель:      https://$PANEL_DOMAIN"
        info "Подписка:    https://$SUB_DOMAIN"
        info "Selfsteal:   http://$SELFSTEAL_DOMAIN (маскировочный сайт, можно повесить свой TLS отдельно)"
    else
        info "Панель (HTTP):      http://$PANEL_DOMAIN"
        info "Подписка (HTTP):    http://$SUB_DOMAIN"
        info "Selfsteal (HTTP):   http://$SELFSTEAL_DOMAIN"
        warn "HTTPS для панели/подписки пока не настроен. Можно использовать Cloudflare/прокси или запустить установку повторно с TLS."
    fi

    echo
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
