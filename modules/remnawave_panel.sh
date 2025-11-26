#!/bin/bash
# ============================================================ #
# ==             МОДУЛЬ REMNAWAVE: ТОЛЬКО ПАНЕЛЬ             == #
# ============================================================ #
#
# Устанавливает только панель Remnawave на этот сервер
# (без локальной ноды), настраивает её через HTTP API и
# готовит базовый конфиг для будущих нод.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# === ВНУТРЕННИЕ ХЕЛПЕРЫ (панель-only) ========================

# --- генерация служебных значений -----------------------------

_remna_panel_generate_password() {
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

_remna_panel_generate_user() {
    # Короткий псевдоним/юзернейм для METRICS_USER и прочего
    tr -dc 'a-zA-Z' </dev/urandom | head -c 8
}

_remna_panel_prepare_dir() {
    # Готовим /opt/remnawave
    run_cmd mkdir -p /opt/remnawave || return 1
    return 0
}

# --- проверка доменов (по мотивам donor check_domain) ---------

_remna_panel_check_domain() {
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
            warn "Домен '$domain' сейчас указывает на IP Cloudflare ($domain_ip)."
            info "Если это домен панели/сабы — можешь оставить прокси. Если что-то идёт не так, выключи оранжевое облако (DNS only)."
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

_remna_panel_api_request() {
    local method="$1"
    local url="$2"
    local token="${3:-}"
    local data="${4:-}"

    local args=(-s -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "X-Remnawave-Client-Type: reshala-panel")

    if [[ -n "$token" ]]; then
        args+=( -H "Authorization: Bearer $token" )
    fi
    if [[ -n "$data" ]]; then
        args+=( -d "$data" )
    fi

    curl "${args[@]}"
}

_remna_panel_api_register_superadmin() {
    local domain_url="$1"   # host:port, без схемы
    local username="$2"
    local password="$3"

    local body
    body=$(jq -n --arg u "$username" --arg p "$password" '{username:$u,password:$p}') || return 1

    local resp
    resp=$(_remna_panel_api_request "POST" "http://$domain_url/api/auth/register" "" "$body") || true

    if [[ -z "$resp" ]]; then
        err "Панель не ответила на /api/auth/register. Смотри docker-логи Remnawave."
        return 1
    fi

    local token
    token=$(echo "$resp" | jq -r '.response.accessToken // .accessToken // empty') || true
    if [[ -z "$token" || "$token" == "null" ]]; then
        err "Не смог вытащить accessToken из ответа регистрации панели."
        log "Remnawave panel register response: $resp"
        return 1
    fi

    echo "$token"
}

_remna_panel_api_generate_x25519() {
    local domain_url="$1"
    local token="$2"

    local resp
    resp=$(_remna_panel_api_request "GET" "http://$domain_url/api/system/tools/x25519/generate" "$token") || true
    if [[ -з "$resp" ]]; then
        err "Панель не ответила на генерацию x25519-ключей."
        return 1
    fi

    local priv
    priv=$(echo "$resp" | jq -r '.response.keypairs[0].privateKey // empty') || true
    if [[ -з "$priv" || "$priv" == "null" ]]; then
        err "Не смог вытащить privateKey из ответа x25519."
        log "panel x25519 response: $resp"
        return 1
    fi

    echo "$priv"
}

_remna_panel_api_create_config_profile() {
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
    resp=$(_remna_panel_api_request "POST" "http://$domain_url/api/config-profiles" "$token" "$body") || true
    if [[ -з "$resp" ]]; then
        err "Не получил ответ от /api/config-profiles при создании профиля панели."
        return 1
    fi

    local cfg inbound
    cfg=$(echo "$resp" | jq -r '.response.uuid // empty') || true
    inbound=$(echo "$resp" | jq -r '.response.inbounds[0].uuid // empty') || true

    if [[ -з "$cfg" || -з "$inbound" || "$cfg" == "null" || "$inbound" == "null" ]]; then
        err "API вернуло кривые UUID для config profile/inbound (панель)."
        log "panel create_config_profile response: $resp"
        return 1
    fi

    echo "$cfg $inbound"
}

# --- подготовка .env / docker-compose / nginx -----------------

_remna_panel_write_env_and_compose() {
    local panel_domain="$1"
    local sub_domain="$2"
    local superadmin_username="$3"
    local superadmin_password="$4"

    local metrics_user metrics_pass
    metrics_user=$(_remna_panel_generate_user)
    metrics_pass=$(_remna_panel_generate_user)

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

    # nginx-конфиг: пока БЕЗ TLS, только HTTP (TLS добавим позже/через CF)
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
EOL

    # INSTALL_INFO с доменами и кредами панельного админа
    cat > /opt/remnawave/INSTALL_INFO <<EOL
PANEL_DOMAIN=$panel_domain
SUB_DOMAIN=$sub_domain
SUPERADMIN_USERNAME=$superadmin_username
SUPERADMIN_PASSWORD=$superadmin_password
EOL
}

_remna_panel_install_wizard() {
    clear
    menu_header "Remnawave: только панель"
    echo
    echo "   Ставим только панель, ноды потом можно раскидать через Skynet."
    echo

    local PANEL_DOMAIN SUB_DOMAIN SUPERADMIN_USERNAME
    PANEL_DOMAIN=$(safe_read "Домен панели (panel.example.com): " "")
    SUB_DOMAIN=$(safe_read "Домен подписки (sub.example.com): " "")
    SUPERADMIN_USERNAME=$(safe_read "Логин суперадмина панели: " "boss")

    if [[ -з "$PANEL_DOMAIN" || -з "$SUB_DOMAIN" ]]; then
        err "Без доменов панели и подписки никуда."
        return 1
    fi
    if [[ "$PANEL_DOMAIN" == "$SUB_DOMAIN" ]]; then
        err "Домен панели и подписки должны отличаться."
        return 1
    fi

    info "Проверяю, что домены реально смотрят на этот сервер..."
    local rc

    _remna_panel_check_domain "$PANEL_DOMAIN" true true
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка прервана по твоему запросу на проверке домена панели."
        return 1
    fi

    _remna_panel_check_domain "$SUB_DOMAIN" true true
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка прервана по твоему запросу на проверке домена подписки."
        return 1
    fi

    info "Готовлю рабочую директорию /opt/remnawave..."
    if ! _remna_panel_prepare_dir; then
        err "Не смог подготовить /opt/remnawave. Смотри логи."
        return 1
    fi

    local SUPERADMIN_PASSWORD
    SUPERADMIN_PASSWORD=$(_remna_panel_generate_password)

    log "Remnawave PANEL install; panel=$PANEL_DOMAIN sub=$SUB_DOMAIN user=$SUPERADMIN_USERNAME"

    info "Пишу .env, docker-compose.yml и nginx.conf под твои домены..."
    _remna_panel_write_env_and_compose "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD" || {
        err "Не смог собрать файлы окружения Remnawave (панель)."
        return 1
    }

    info "Стартую Docker-композ Remnawave панели (это займет пару минут)..."
    (
        cd /opt/remnawave && run_cmd docker compose up -d
    ) || {
        err "docker compose up -d для Remnawave (панель) отработал с ошибкой. Смотри docker-логи."
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
    token=$(_remna_panel_api_register_superadmin "$domain_url" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD") || return 1

    info "Генерю x25519-ключи для базового конфига..."
    local private_key
    private_key=$(_remna_panel_api_generate_x25519 "$domain_url" "$token") || return 1

    info "Создаю базовый config-profile для будущих нод..."
    local cfg inbound
    read -r cfg inbound < <(_remna_panel_api_create_config_profile "$domain_url" "$token" "BasePanelConfig" "$PANEL_DOMAIN" "$private_key") || return 1

    ok "Панель Remnawave поднята, настроена и готова принимать ноды."
    echo
    info "Адрес панели: https://$PANEL_DOMAIN (пока без TLS, ставь Cloudflare/прокси или добавим cert'ы позже)"
    info "Логин суперадмина: $SUPERADMIN_USERNAME"
    info "Пароль суперадмина: $SUPERADMIN_PASSWORD"
    echo
    wait_for_enter
}

_remna_panel_install_wizard() {
    clear
    menu_header "Remnawave: только панель"
    echo
    echo "   Ставим только панель, ноды потом можно раскидать через Skynet."
    echo

    local PANEL_DOMAIN SUB_DOMAIN SUPERADMIN_USERNAME
    PANEL_DOMAIN=$(safe_read "Домен панели (panel.example.com): " "")
    SUB_DOMAIN=$(safe_read "Домен подписки (sub.example.com): " "")
    SUPERADMIN_USERNAME=$(safe_read "Логин суперадмина панели: " "boss")

    if [[ -z "$PANEL_DOMAIN" || -z "$SUB_DOMAIN" ]]; then
        err "Без доменов панели и подписки никуда."
        return 1
    fi
    if [[ "$PANEL_DOMAIN" == "$SUB_DOMAIN" ]]; then
        err "Домен панели и подписки должны отличаться."
        return 1
    fi

    info "Каркас мастера панели готов. Тяжёлая логика из донора ещё не перенесена."
    wait_for_enter
}

# === МЕНЮ МОДУЛЯ =============================================

show_remnawave_panel_menu() {
    while true; do
        clear
        menu_header "Remnawave: установка панели"
        echo
        echo "   [1] Установить панель на этот сервер"
        echo "   [2] (WIP) Управление уже установленной панелью"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "")

        case "$choice" in
            1) _remna_panel_install_wizard ;;
            2) warn "Меню управления панелью ещё в разработке."; sleep 2 ;;
            [bB]) break ;;
            *) err "Нет такого пункта, смотри внимательнее, босс." ;;
        esac
    done
}
