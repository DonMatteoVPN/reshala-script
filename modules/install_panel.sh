#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ REMNAWAVE: ULTIMATE HIGH-LOAD (RESHALA ED.)   ==
# ============================================================ #

# --- Цвета ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'

# --- Константы ---
INSTALL_DIR="/opt/remnawave"
LOG_FILE="/var/log/reshala_remna.log"

# --- Хелперы ---
log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE" >/dev/null; }
msg_info() { printf "%b\n" "${C_CYAN}ℹ️  $1${C_RESET}"; log "INFO: $1"; }
msg_ok() { printf "%b\n" "${C_GREEN}✅ $1${C_RESET}"; log "OK: $1"; }
msg_warn() { printf "%b\n" "${C_YELLOW}⚠️  $1${C_RESET}"; log "WARN: $1"; }
msg_err() { printf "%b\n" "${C_RED}❌ $1${C_RESET}"; log "ERROR: $1"; exit 1; }
run_cmd() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
generate_pass() { < /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24; }
generate_user() { < /dev/urandom tr -dc 'a-z' | head -c 8; }

# ============================================================ #
#                    ПРОВЕРКИ И ЗАВИСИМОСТИ                    #
# ============================================================ #

check_dependencies() {
    msg_info "Проверяю инструменты..."
    local deps=(curl wget jq openssl git cron)
    local install_needed=0
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then install_needed=1; break; fi
    done

    if [ $install_needed -eq 1 ]; then
        msg_warn "Доустанавливаю софт..."
        run_cmd apt-get update -y
        run_cmd apt-get install -y "${deps[@]}" ca-certificates gnupg lsb-release ufw
    fi

    if ! command -v docker &> /dev/null; then
        msg_warn "Ставлю Docker..."
        curl -fsSL https://get.docker.com | sh
        run_cmd systemctl enable --now docker
    fi
    
    if ! command -v certbot &> /dev/null; then
        msg_warn "Ставлю Certbot..."
        run_cmd apt-get install -y certbot python3-certbot-dns-cloudflare
    fi
}

check_domain_ip() {
    local domain="$1"
    local strict="$2"
    msg_info "Чекаю домен $domain..."
    local domain_ip=$(dig +short A "$domain" | head -n 1)
    local server_ip=$(curl -s -4 ifconfig.me)

    if [ -z "$domain_ip" ]; then msg_err "Домен $domain пустой. DNS настрой, э!"; fi
    if [ "$domain_ip" != "$server_ip" ]; then
        local is_cf=$(curl -s https://www.cloudflare.com/ips-v4 | grep -f <(echo "$domain_ip") || echo "no")
        if [[ "$is_cf" != "no" ]]; then
             msg_warn "Домен за Cloudflare (Proxy). Ок."
             if [ "$strict" == "true" ]; then
                msg_err "Для Self-Steal домена ноды Cloudflare Proxy НЕЛЬЗЯ! Выключи облачко (DNS Only)."
             fi
        else
            msg_warn "IP домена ($domain_ip) != IP сервера ($server_ip)."
            read -p "Продолжаем? (y/n): " confirm
            [[ "$confirm" != "y" ]] && msg_err "Отмена."
        fi
    else
        msg_ok "IP совпадает."
    fi
}

# ============================================================ #
#                    СЕРТИФИКАТЫ                               #
# ============================================================ #

issue_certs() {
    local domains=("$@")
    echo ""
    msg_info "Выбери метод получения сертификатов:"
    echo "   1. Cloudflare API (Wildcard, если домен на CF)"
    echo "   2. Let's Encrypt (HTTP-01, нужен 80 порт)"
    read -p "Выбор (1/2): " method

    if [ "$method" == "1" ]; then
        read -p "Email Cloudflare: " cf_email
        read -p "Global API Key / Token: " cf_key
        mkdir -p ~/.secrets/certbot
        echo "dns_cloudflare_email = $cf_email" > ~/.secrets/certbot/cloudflare.ini
        echo "dns_cloudflare_api_key = $cf_key" >> ~/.secrets/certbot/cloudflare.ini
        chmod 600 ~/.secrets/certbot/cloudflare.ini

        for domain in "${domains[@]}"; do
            msg_info "Генерирую Wildcard для $domain..."
            local base_domain=$(echo "$domain" | awk -F'.' '{print $(NF-1)"."$NF}')
            certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 -d "$base_domain" -d "*.$base_domain" \
                --email "$cf_email" --agree-tos --non-interactive --key-type ecdsa
        done
    elif [ "$method" == "2" ]; then
        read -p "Email для Let's Encrypt: " le_email
        run_cmd ufw allow 80/tcp
        for domain in "${domains[@]}"; do
            msg_info "Генерирую сертификат для $domain..."
            certbot certonly --standalone -d "$domain" --email "$le_email" --agree-tos --non-interactive --key-type ecdsa
        done
        run_cmd ufw delete allow 80/tcp
    else
        msg_err "Кривой выбор."
    fi
}

# ============================================================ #
#                    API ФУНКЦИИ                               #
# ============================================================ #

api_req() {
    local method=$1; local url=$2; local token=$3; local data=$4
    local auth_header=""; [ -n "$token" ] && auth_header="Authorization: Bearer $token"
    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" -H "$auth_header" -H "Content-Type: application/json" -d "$data"
    else
        curl -s -X "$method" "$url" -H "$auth_header" -H "Content-Type: application/json"
    fi
}

# ============================================================ #
#                    TINY AUTH ГЕНЕРАТОР                       #
# ============================================================ #

generate_tinyauth_hash() {
    local user=$1
    local pass=$2
    msg_info "Генерирую хэш для TinyAuth..."
    
    # Используем docker run для генерации, передавая ввод через pipe
    # Формат ввода: username -> enter -> password -> enter -> format (docker) -> enter
    local OUTPUT=$(printf "$user\n$pass\n$pass\ndocker\n" | docker run --rm -i ghcr.io/maposia/remnawave-tinyauth:latest user create --interactive 2>/dev/null)
    
    # Парсим вывод, ищем строку вида user:hash
    local HASH=$(echo "$OUTPUT" | grep -oE "$user:\\\$2[abxy]\\\$.{56}")
    
    if [ -z "$HASH" ]; then
        # Фолбек, если греп не сработал, пробуем найти просто длинную строку с $2
        HASH=$(echo "$OUTPUT" | grep -oE "\\\$2[abxy]\\\$.{56}")
        if [ -n "$HASH" ]; then HASH="$user:$HASH"; fi
    fi

    if [ -z "$HASH" ]; then
        msg_err "Не удалось сгенерировать хэш TinyAuth. Вывод: $OUTPUT"
    fi
    
    echo "$HASH"
}

# ============================================================ #
#                    УСТАНОВКА ПАНЕЛИ (HIGH LOAD)              #
# ============================================================ #

install_panel_highload() {
    msg_info "Начинаем сборку High-Load Панели..."

    # 1. Сбор доменов
    read -p "Домен ПАНЕЛИ (panel.domain.com): " DOMAIN_PANEL
    check_domain_ip "$DOMAIN_PANEL" "false"
    
    read -p "Домен ПОДПИСКИ (sub.domain.com): " DOMAIN_SUB
    check_domain_ip "$DOMAIN_SUB" "false"

    read -p "Домен АВТОРИЗАЦИИ TinyAuth (auth.domain.com): " DOMAIN_AUTH
    check_domain_ip "$DOMAIN_AUTH" "false"

    # Опция Mini App
    local INSTALL_MINIAPP="false"
    local DOMAIN_APP=""
    read -p "Ставим Telegram Mini App? (y/n): " confirm_app
    if [[ "$confirm_app" == "y" ]]; then
        INSTALL_MINIAPP="true"
        read -p "Домен MINI APP (app.domain.com): " DOMAIN_APP
        check_domain_ip "$DOMAIN_APP" "false"
    fi

    # 2. Сертификаты
    local domains_to_cert=("$DOMAIN_PANEL" "$DOMAIN_SUB" "$DOMAIN_AUTH")
    if [ "$INSTALL_MINIAPP" == "true" ]; then domains_to_cert+=("$DOMAIN_APP"); fi
    issue_certs "${domains_to_cert[@]}"

    # 3. Данные TinyAuth
    msg_info "Настройка защиты TinyAuth..."
    read -p "Придумай Логин для входа в панель (защита): " TA_USER
    read -p "Придумай Пароль для входа в панель: " TA_PASS
    local TA_HASH=$(generate_tinyauth_hash "$TA_USER" "$TA_PASS")
    local TA_SECRET=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    msg_ok "Хэш TinyAuth сгенерирован."

    # 4. Данные Панели
    local P_USER=$(generate_user)
    local P_PASS=$(generate_pass)
    local JWT_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
    local WEBHOOK_SECRET=$(openssl rand -hex 32)

    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

    # 5. .env Файл
    cat > .env <<EOL
### APP ###
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1

### REDIS ###
REDIS_HOST=remnawave-redis
REDIS_PORT=6379

### JWT ###
JWT_AUTH_SECRET=$JWT_SECRET
JWT_API_TOKENS_SECRET=$JWT_SECRET
JWT_AUTH_LIFETIME=168

### TELEGRAM ###
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
TELEGRAM_NOTIFY_USERS_CHAT_ID=change_me
TELEGRAM_NOTIFY_NODES_CHAT_ID=change_me
TELEGRAM_NOTIFY_CRM_CHAT_ID=change_me
TELEGRAM_OAUTH_ENABLED=false

### FRONTEND ###
FRONT_END_DOMAIN=$DOMAIN_PANEL
SUB_PUBLIC_DOMAIN=$DOMAIN_SUB

### SWAGGER ###
IS_DOCS_ENABLED=false
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar

### METRICS ###
METRICS_USER=$(generate_user)
METRICS_PASS=$(generate_pass)

### WEBHOOK ###
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://hooks.example.com/webhook
WEBHOOK_SECRET_HEADER=$WEBHOOK_SECRET

### HWID ###
HWID_DEVICE_LIMIT_ENABLED=false
HWID_FALLBACK_DEVICE_LIMIT=3
HWID_MAX_DEVICES_ANNOUNCE="Limit reached."

### BANDWIDTH ###
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=true
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80, 95]

### DB ###
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### MINI APP ###
REMNAWAVE_PANEL_URL=http://remnawave-scheduler:3000
REMNAWAVE_TOKEN=PLACEHOLDER_TOKEN
BUY_LINK=https://t.me/DonMatteo_VPN_bot
AUTH_API_KEY=$(openssl rand -hex 32)
REDIRECT_LINK=https://$DOMAIN_APP/myredirect/?telegram&redirect_to=
EOL

    # 6. docker-compose.yml
    cat > docker-compose.yml <<EOL
x-base: &base
  image: remnawave/backend:latest
  restart: always
  env_file:
    - .env
  networks:
    - remnawave-network
  logging:
    driver: 'json-file'
    options: { max-size: '25m', max-file: '4' }

services:
  api:
    <<: *base
    network_mode: "service:remnawave-scheduler"
    networks: {}
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-api'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
      remnawave-scheduler: { condition: service_healthy }

  remnawave-scheduler:
    <<: *base
    container_name: 'remnawave-scheduler'
    hostname: remnawave-scheduler
    entrypoint: ['/bin/sh', 'docker-entrypoint.sh']
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-scheduler'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
    ports:
      - '127.0.0.1:3000:3000'
      - '127.0.0.1:3001:3001'
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

  remnawave-processor:
    <<: *base
    container_name: 'remnawave-processor'
    hostname: remnawave-processor
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-jobs'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
      remnawave-scheduler: { condition: service_healthy }

  remnawave-db:
    image: postgres:17.6
    container_name: 'remnawave-db'
    hostname: remnawave-db
    restart: always
    env_file: [ .env ]
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 10s
      timeout: 5s
      retries: 5

  remnawave-redis:
    image: valkey/valkey:8.1.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    networks:
      - remnawave-network
    volumes:
      - remnawave-redis-data:/data
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 10s
      timeout: 5s
      retries: 5

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave-scheduler:3000
      - APP_PORT=3010
      - META_TITLE=Remnawave
      - META_DESCRIPTION=VPN Service
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }

  tinyauth:
    image: ghcr.io/maposia/remnawave-tinyauth:latest
    container_name: tinyauth
    hostname: tinyauth
    restart: always
    ports:
      - '127.0.0.1:3002:3002'
    networks:
      - remnawave-network
    environment:
      - PORT=3002
      - APP_URL=https://$DOMAIN_AUTH
      - USERS=$TA_HASH
      - SECRET=$TA_SECRET
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    network_mode: host
    depends_on:
      - api
      - remnawave-subscription-page
      - tinyauth
    logging:
      driver: 'journald'
      options:
        tag: "nginx.remnawave"
EOL

    # Добавляем Mini App в docker-compose если нужно
    if [ "$INSTALL_MINIAPP" == "true" ]; then
        cat >> docker-compose.yml <<EOL

  remnawave-mini-app:
    image: ghcr.io/maposia/remnawave-telegram-sub-mini-app:latest
    container_name: remnawave-telegram-mini-app
    hostname: remnawave-telegram-mini-app
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3020:3020'
    networks:
      - remnawave-network
EOL
    fi

    # Финализируем docker-compose
    cat >> docker-compose.yml <<EOL

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge

volumes:
  remnawave-db-data:
  remnawave-redis-data:
EOL

    # 7. nginx.conf
    # Определяем пути к сертификатам
    get_cert_path() {
        local d=$1
        local p="/etc/letsencrypt/live/$d"
        [ ! -d "$p" ] && p="/etc/letsencrypt/live/$(echo $d | awk -F'.' '{print $(NF-1)"."$NF}')"
        echo "$p"
    }
    
    local CP_PANEL=$(get_cert_path "$DOMAIN_PANEL")
    local CP_SUB=$(get_cert_path "$DOMAIN_SUB")
    local CP_AUTH=$(get_cert_path "$DOMAIN_AUTH")
    local CP_APP=""
    if [ "$INSTALL_MINIAPP" == "true" ]; then CP_APP=$(get_cert_path "$DOMAIN_APP"); fi

    cat > nginx.conf <<EOL
worker_processes auto;
events { worker_connections 1024; }

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    upstream tinyauth { server 127.0.0.1:3002; }
    upstream remnawave { server 127.0.0.1:3000; }
    upstream subpage { server 127.0.0.1:3010; }
    upstream miniapp { server 127.0.0.1:3020; }

    # --- TINY AUTH ---
    server {
        server_name $DOMAIN_AUTH;
        listen 443 ssl;
        http2 on;
        ssl_certificate "$CP_AUTH/fullchain.pem";
        ssl_certificate_key "$CP_AUTH/privkey.pem";
        
        location / {
            proxy_pass http://tinyauth;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    # --- PANEL (PROTECTED) ---
    server {
        server_name $DOMAIN_PANEL;
        listen 443 ssl;
        http2 on;
        ssl_certificate "$CP_PANEL/fullchain.pem";
        ssl_certificate_key "$CP_PANEL/privkey.pem";

        location / {
            auth_request /tinyauth;
            error_page 401 = @tinyauth_login;

            proxy_pass http://remnawave;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location /tinyauth {
            proxy_pass http://tinyauth/api/auth/nginx;
            proxy_set_header x-forwarded-proto \$scheme;
            proxy_set_header x-forwarded-host \$http_host;
            proxy_set_header x-forwarded-uri \$request_uri;
        }

        location @tinyauth_login {
            return 302 https://$DOMAIN_AUTH/login?redirect_uri=\$scheme://\$http_host\$request_uri;
        }
    }

    # --- SUBSCRIPTION PAGE ---
    server {
        server_name $DOMAIN_SUB;
        listen 443 ssl;
        http2 on;
        ssl_certificate "$CP_SUB/fullchain.pem";
        ssl_certificate_key "$CP_SUB/privkey.pem";

        location / {
            proxy_pass http://subpage;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
EOL

    if [ "$INSTALL_MINIAPP" == "true" ]; then
        cat >> nginx.conf <<EOL

    # --- MINI APP ---
    server {
        server_name $DOMAIN_APP;
        listen 443 ssl;
        http2 on;
        ssl_certificate "$CP_APP/fullchain.pem";
        ssl_certificate_key "$CP_APP/privkey.pem";

        location / {
            proxy_pass http://miniapp;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
EOL
    fi
    echo "}" >> nginx.conf

    # 8. Запуск
    msg_info "Запускаю систему..."
    run_cmd docker compose up -d

    msg_info "Жду старта API (15 сек)..."
    sleep 15

    # 9. Регистрация и Токен
    msg_info "Регаю админа..."
    local REG_RESP=$(api_req "POST" "http://127.0.0.1:3000/api/auth/register" "" "{\"username\":\"$P_USER\",\"password\":\"$P_PASS\"}")
    local TOKEN=$(echo $REG_RESP | jq -r '.response.accessToken')

    if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
        msg_err "Ошибка регистрации. Ответ: $REG_RESP"
    fi
    echo "$TOKEN" > "$INSTALL_DIR/token"

    # 10. Обновление токена для Mini App
    if [ "$INSTALL_MINIAPP" == "true" ]; then
        msg_info "Прописываю токен в Mini App..."
        sed -i "s|PLACEHOLDER_TOKEN|$TOKEN|g" .env
        run_cmd docker compose up -d remnawave-mini-app
    fi

    # 11. Ключи и очистка
    local PUB_KEY_RESP=$(api_req "GET" "http://127.0.0.1:3000/api/keygen" "$TOKEN")
    local DEF_UUID=$(api_req "GET" "http://127.0.0.1:3000/api/config-profiles" "$TOKEN" | jq -r '.response.configProfiles[] | select(.name=="Default-Profile") | .uuid')
    [ -n "$DEF_UUID" ] && api_req "DELETE" "http://127.0.0.1:3000/api/config-profiles/$DEF_UUID" "$TOKEN"

    echo ""
    msg_ok "HIGH-LOAD ПАНЕЛЬ УСТАНОВЛЕНА!"
    echo "----------------------------------------------------"
    echo "🔗 Панель: https://$DOMAIN_PANEL"
    echo "🛡️ TinyAuth: $TA_USER / $TA_PASS"
    echo "👤 Админ:    $P_USER"
    echo "🔑 Пароль:   $P_PASS"
    if [ "$INSTALL_MINIAPP" == "true" ]; then
        echo "📱 Mini App: https://$DOMAIN_APP"
    fi
    echo "----------------------------------------------------"
    echo "Не забудь добавить ноду через меню!"
}

# ============================================================ #
#                    МЕНЮ                                      #
# ============================================================ #

show_menu() {
    clear
    printf "%b\n" "${C_CYAN}--- REMNAWAVE: HIGH-LOAD & SECURITY ---${C_RESET}"
    echo "1. 🔥 Установить ПАНЕЛЬ (High-Load + TinyAuth + MiniApp)"
    echo "2. ➕ Добавить НОДУ (Выполнять на ПАНЕЛИ)"
    echo "3. 🧱 Установить НОДУ (Выполнять на НОДЕ)"
    echo "0. Назад"
    echo "---------------------------------------------------"
    read -p "Твой выбор: " choice

    case $choice in
        1) check_dependencies; install_panel_highload ;;
        2) check_dependencies; add_node_on_panel ;; # Функция из прошлого ответа (она не менялась)
        3) check_dependencies; install_node_only ;; # Функция из прошлого ответа (она не менялась)
        0) exit 0 ;;
        *) msg_err "Мимо." ;;
    esac
}

add_node_on_panel() {
    msg_info "Добавляем ноду в базу панели..."
    
    if [ ! -f "$INSTALL_DIR/token" ]; then
        msg_warn "Токен не найден. Введи данные админа панели."
        read -p "Логин: " P_USER
        read -p "Пароль: " P_PASS
        local LOGIN_RESP=$(api_req "POST" "http://127.0.0.1:3000/api/auth/login" "" "{\"username\":\"$P_USER\",\"password\":\"$P_PASS\"}")
        local TOKEN=$(echo $LOGIN_RESP | jq -r '.response.accessToken')
        if [ "$TOKEN" == "null" ]; then msg_err "Неверный логин/пароль."; fi
    else
        local TOKEN=$(cat "$INSTALL_DIR/token")
    fi

    read -p "Введи домен НОДЫ (node.domain.com): " NODE_DOMAIN
    read -p "Придумай имя ноды (например, Germany): " NODE_NAME

    # Генерируем ключи Xray
    local XRAY_KEYS=$(api_req "GET" "http://127.0.0.1:3000/api/system/tools/x25519/generate" "$TOKEN")
    local PRIV_KEY=$(echo $XRAY_KEYS | jq -r '.response.keypairs[0].privateKey')
    local SHORT_ID=$(openssl rand -hex 8)

    # Создаем профиль
    local CONF_JSON=$(jq -n \
        --arg name "$NODE_NAME" \
        --arg domain "$NODE_DOMAIN" \
        --arg pk "$PRIV_KEY" \
        --arg sid "$SHORT_ID" \
        '{
            name: $name,
            config: {
                log: {loglevel: "warning"},
                inbounds: [{
                    tag: "Steal", port: 443, protocol: "vless",
                    streamSettings: {
                        network: "tcp", security: "reality",
                        realitySettings: {
                            show: false, dest: "127.0.0.1:443", xver: 0,
                            serverNames: [$domain], privateKey: $pk, shortIds: [$sid]
                        }
                    }
                }],
                outbounds: [{tag: "DIRECT", protocol: "freedom"}]
            }
        }')
    
    local CONF_RESP=$(api_req "POST" "http://127.0.0.1:3000/api/config-profiles" "$TOKEN" "$CONF_JSON")
    local CONF_UUID=$(echo $CONF_RESP | jq -r '.response.uuid')
    local INB_UUID=$(echo $CONF_RESP | jq -r '.response.inbounds[0].uuid')

    if [ "$CONF_UUID" == "null" ]; then msg_err "Ошибка создания профиля: $CONF_RESP"; fi

    # Создаем ноду
    local NODE_JSON=$(jq -n \
        --arg conf "$CONF_UUID" \
        --arg inb "$INB_UUID" \
        --arg addr "$NODE_DOMAIN" \
        --arg name "$NODE_NAME" \
        '{
            name: $name, address: $addr, port: 2222,
            configProfile: {activeConfigProfileUuid: $conf, activeInbounds: [$inb]}
        }')
    api_req "POST" "http://127.0.0.1:3000/api/nodes" "$TOKEN" "$NODE_JSON"

    # Создаем хост
    local HOST_JSON=$(jq -n \
        --arg conf "$CONF_UUID" \
        --arg inb "$INB_UUID" \
        --arg addr "$NODE_DOMAIN" \
        --arg remark "$NODE_NAME" \
        '{
            remark: $remark, address: $addr, port: 443, sni: $addr,
            inbound: {configProfileUuid: $conf, configProfileInboundUuid: $inb}
        }')
    api_req "POST" "http://127.0.0.1:3000/api/hosts" "$TOKEN" "$HOST_JSON"

    # Получаем Public Key панели
    local PUB_KEY_RESP=$(api_req "GET" "http://127.0.0.1:3000/api/keygen" "$TOKEN")
    local PANEL_PUB_KEY=$(echo $PUB_KEY_RESP | jq -r '.response.pubKey')

    echo ""
    msg_ok "НОДА ДОБАВЛЕНА В ПАНЕЛЬ!"
    echo "Теперь иди на сервер НОДЫ и при установке введи эти данные:"
    echo "----------------------------------------------------"
    echo "🌍 Домен ноды: $NODE_DOMAIN"
    echo "🔑 SECRET_KEY: $PANEL_PUB_KEY"
    echo "----------------------------------------------------"
}

# ============================================================ #
#                    ЧАСТЬ 3: УСТАНОВКА НОДЫ (НА СЕРВЕРЕ)      #
# ============================================================ #

install_node_only() {
    msg_info "Ставим НОДУ (Slave Server)..."
    
    read -p "Введи домен НОДЫ (тот же, что добавлял в панели): " DOMAIN_NODE
    check_domain_ip "$DOMAIN_NODE" "true"
    
    read -p "Введи SECRET_KEY (из панели): " SECRET_KEY
    if [ -z "$SECRET_KEY" ]; then msg_err "Ключ не может быть пустым!"; fi

    # Сертификат для Self-Steal
    issue_certs "$DOMAIN_NODE"

    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

    # Путь к сертификату
    local CERT_PATH_NODE="/etc/letsencrypt/live/$DOMAIN_NODE"
    [ ! -d "$CERT_PATH_NODE" ] && CERT_PATH_NODE="/etc/letsencrypt/live/$(echo $DOMAIN_NODE | awk -F'.' '{print $(NF-1)"."$NF}')"

    # docker-compose.yml
    cat > docker-compose.yml <<EOL
services:
  remnanode:
    image: remnawave/node:latest
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$SECRET_KEY
    volumes:
      - /dev/shm:/dev/shm:rw

  remnawave-nginx:
    image: nginx:alpine
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /var/www/html:/var/www/html:ro
      - $CERT_PATH_NODE:/etc/nginx/ssl/node:ro
EOL

    # nginx.conf (Self-Steal)
    cat > nginx.conf <<EOL
server {
    server_name $DOMAIN_NODE;
    listen 443 ssl;
    http2 on;
    ssl_certificate /etc/nginx/ssl/node/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/node/privkey.pem;
    
    root /var/www/html;
    index index.html;
}
EOL

    # Маскировка
    msg_info "Качаю маскировку..."
    mkdir -p /var/www/html
    wget -q -O /tmp/site.zip https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip
    unzip -o -q /tmp/site.zip -d /tmp/
    cp -r /tmp/simple-web-templates-main/Crypto/* /var/www/html/
    rm -rf /tmp/site.zip /tmp/simple-web-templates-main

    # Открываем порт
    run_cmd ufw allow 2222/tcp

    msg_info "Запускаю ноду..."
    run_cmd docker compose up -d

    echo ""
    msg_ok "НОДА ЗАПУЩЕНА!"
    echo "Если ты всё сделал правильно в панели, она должна загореться зеленым."
}

show_menu