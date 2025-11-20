#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ: REMNAWAVE MANAGER (ULTRA EDITION)            ==
# ==   Based on eGames logic, powered by RESHALA config     ==
# ============================================================ #

# --- Цвета ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m';

# --- Константы ---
PANEL_DIR="/opt/remnawave"
NODE_DIR="/opt/remnanode"
NGINX_CONF_DIR="/etc/nginx"
MINIAPP_DIR="/opt/remnawave-bedolaga-telegram-bot/miniapp"

# --- Утилиты ---
run_cmd() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
log() { echo -e "${C_CYAN}[RESHALA]${C_RESET} $1"; }
error() { echo -e "${C_RED}[ERROR] $1${C_RESET}"; exit 1; }
wait_enter() { read -p "Нажми Enter, чтобы продолжить..."; }

# --- Проверка зависимостей ---
check_dependencies() {
    local missing=0
    for cmd in docker nginx certbot htpasswd curl jq; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${C_YELLOW}⚠️ Утилита $cmd не найдена. Устанавливаю...${C_RESET}"
            if [[ "$cmd" == "htpasswd" ]]; then
                run_cmd apt-get update -q && run_cmd apt-get install -y apache2-utils -q
            else
                run_cmd apt-get update -q && run_cmd apt-get install -y $cmd -q
            fi
        fi
    done
}

# --- ГЕНЕРАТОРЫ ---
generate_tinyauth_hash() { htpasswd -nB -C 10 "$1" "$2" | cut -d ":" -f 2; }
generate_secret() { openssl rand -hex 32; }

# ============================================================ #
#                    ЛОГИКА УСТАНОВКИ ПАНЕЛИ                   #
# ============================================================ #
install_panel_logic() {
    clear
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_CYAN}║           УСТАНОВКА ПАНЕЛИ REMNAWAVE (HIGH-LOAD)             ║${C_RESET}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    
    check_dependencies

    # 1. Сбор данных
    echo -e "${C_YELLOW}--- НАСТРОЙКА ДОМЕНОВ ---${C_RESET}"
    read -p "Введи ГЛАВНЫЙ домен (без https, например: donmatteo.monster): " MAIN_DOMAIN
    if [[ -z "$MAIN_DOMAIN" ]]; then error "Домен нужен, брат."; fi

    echo -e "\n${C_YELLOW}--- ЗАЩИТА (TinyAuth) ---${C_RESET}"
    read -p "Логин админа: " TA_USER
    read -s -p "Пароль админа: " TA_PASS
    echo ""

    echo -e "\n${C_YELLOW}--- TELEGRAM ---${C_RESET}"
    read -p "Telegram Bot Token: " TG_BOT_TOKEN
    read -p "Chat ID для уведомлений: " TG_CHAT_ID

    log "🔐 Генерирую ключи..."
    TA_HASH=$(generate_tinyauth_hash "$TA_USER" "$TA_PASS")
    TA_SECRET=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    JWT_SECRET=$(generate_secret)
    API_SECRET=$(generate_secret)
    WEBHOOK_SECRET=$(generate_secret)

    log "📂 Создаю структуру..."
    run_cmd mkdir -p "$PANEL_DIR"
    run_cmd mkdir -p "$MINIAPP_DIR/myredirect"

    # 2. Docker Compose (High-Load)
    log "📝 Создаю docker-compose.yml..."
    cat <<EOF > "$PANEL_DIR/docker-compose.yml"
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
      - META_TITLE=Ваша подписка на VPN
      - META_DESCRIPTION=Свобода и безопасность одним касанием!
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }
    volumes:
      - ./myapp-config.json:/opt/app/frontend/assets/app-config.json:ro

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
    volumes:
       - ./myapp-config.json:/app/public/assets/app-config.json:ro

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    volumes:
      - /etc/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /opt/remnawave-bedolaga-telegram-bot:/opt/remnawave-bedolaga-telegram-bot:ro
    network_mode: host
    depends_on:
      - api
      - remnawave-subscription-page
      - remnawave-mini-app
    logging:
      driver: 'journald'
      options:
        tag: "nginx.remnawave"

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
      - APP_URL=https://auth.$MAIN_DOMAIN
      - USERS=$TA_USER:$TA_HASH
      - SECRET=$TA_SECRET
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge

volumes:
  remnawave-db-data:
  remnawave-redis-data:
EOF

    # 3. .env
    log "📝 Создаю .env..."
    cat <<EOF > "$PANEL_DIR/.env"
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
REDIS_HOST=remnawave-redis
REDIS_PORT=6379
JWT_AUTH_SECRET=$JWT_SECRET
JWT_API_TOKENS_SECRET=$API_SECRET
JWT_AUTH_LIFETIME=168
IS_TELEGRAM_NOTIFICATIONS_ENABLED=true
TELEGRAM_BOT_TOKEN=$TG_BOT_TOKEN
TELEGRAM_NOTIFY_USERS_CHAT_ID=$TG_CHAT_ID
TELEGRAM_NOTIFY_NODES_CHAT_ID=$TG_CHAT_ID
TELEGRAM_NOTIFY_CRM_CHAT_ID=$TG_CHAT_ID
TELEGRAM_OAUTH_ENABLED=true
TELEGRAM_OAUTH_ADMIN_IDS=[]
FRONT_END_DOMAIN=panrem.$MAIN_DOMAIN
SUB_PUBLIC_DOMAIN=subrem.$MAIN_DOMAIN
IS_DOCS_ENABLED=false
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
METRICS_USER=admin
METRICS_PASS=admin
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://hooks.$MAIN_DOMAIN/webhook
WEBHOOK_SECRET_HEADER=$WEBHOOK_SECRET
HWID_DEVICE_LIMIT_ENABLED=false
HWID_FALLBACK_DEVICE_LIMIT=3
HWID_MAX_DEVICES_ANNOUNCE="Вы использовали максимальное количество устройств."
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=true
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80, 95]
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"
REMNAWAVE_PANEL_URL=http://remnawave-scheduler:3000
REMNAWAVE_TOKEN=
BUY_LINK=https://t.me/DonMatteo_VPN_bot
AUTH_API_KEY=
REDIRECT_LINK=https://subapp.$MAIN_DOMAIN/myredirect/?telegram&redirect_to=
EOF

    # 4. myapp-config.json
    log "📝 Заливаю конфиг приложений..."
    cat <<'EOF' > "$PANEL_DIR/myapp-config.json"
{
  "config": {
    "additionalLocales": ["ru"],
    "branding": {
      "logoUrl": "https://lh3.googleusercontent.com/rd-d/ALs6j_FQxFkowBZNSpfISvbAX-ynoZUwhkF2w5ELfknE_gH7yGcsP2hvwoFvW4Aj9dqtz6FVtAkHPl8oo3-Ps9WVcLrtE2YVGV357AfqktJAoyeotXYB01GzngQHyUa5kDfFbJKz8P0zENgAEY63Ak4VEsp4imasl0DCfR_FDcomFVjOyoejE9T8m90TzTo0m8PFw_ZXjDK5MbOpF9HV2q4SLWO2DIkYwoUJcyH_qE0toH4KAGzpmHfYk0DnRZ1Z4JPkZUroPcPXppX9G9F5fGowfeIWReyXw0aSy8D9BvNfA7duAQzXtG7IG1Uf8dY20cNw6b5DEsDKYoryu3Fd8PP54dkBp3ferYsaNmgWCOjNjLTYETqBWgJFfqwLQT9DoXSG7oA0eYY_p1wvllLhfObcYJlMlKcpkKOf291uMmYPz__gJYqOJ23trMResj5j4u_uMyoIIRrI4jF84D4ycklM6C_VJMRREjJtGbvaU47GdRvVtyqVziRtD6g3x24Kj1PiTa3cWPe8Rlnr2hC-YOnL6jBH5fPAB_N2LcwoSwarFM0gA8WRRKfujTna6XDM7xc3x6h5s2DglNiSfdcT0gPQxdmSR4MqPvWz9HZd5WNkH3LQUkDTd7-5NX6yrhvuB-l444Y1b5EE8GTYedLNifncKoh4w4cInlf5eaFyrEAcMlDbm_aeoSOsuTP1uLUyqu48NHyNxiwXLCPgdVQJYqXszr2BImiuzCWvUhzsK_MSnU7OM6bhtRr-i465Z-pFCIXyaye4mBE4PaUxnWk9CMqEyyYYTyf0jMjtNVhz8G1k_dhzOMuR5fiNexvN9e7vk6DfUGQAZUxPB-Xt4rdbyUnaZGumpU1RLldVlqrRtEWPrjo9AWHJfiKmhogKrI2CgifF_09Y2RKGWVhrey4xvYsnGoMTa9BF3uxuHUV7dOXM7CmhJyiXkskQlq6NdsJ8ZeSXptNMkdjWmWuttxsre9Xs_7HdNjZsSEaEAUYX2gPUjXBPUM_xrMnBs60M1v6ugG2W27gwb69F5bZ6GOH83_3WoaR5ycRQX4I5GgTd39uSBaQZuQ=w1809-h921?auditContext=forDisplay",
      "name": "DonMatteo VPN",
      "supportUrl": "https://t.me/DonMatteo_Support_bot"
    }
  },
  "platforms": {
    "ios": [], "android": [], "linux": [], "macos": [], "windows": [], "androidTV": [], "appleTV": []
  }
}
EOF

    # 5. SSL
    log "🔒 Получаю SSL сертификаты..."
    DOMAINS="-d auth.$MAIN_DOMAIN -d panrem.$MAIN_DOMAIN -d subrem.$MAIN_DOMAIN -d hooks.$MAIN_DOMAIN -d miniapp.$MAIN_DOMAIN -d apibot.$MAIN_DOMAIN -d subapp.$MAIN_DOMAIN"
    
    if certbot certonly --nginx --non-interactive --agree-tos -m admin@$MAIN_DOMAIN $DOMAINS; then
        log "✅ Сертификаты получены!"
    else
        log "⚠️ Ошибка Certbot через Nginx. Пробую Standalone..."
        systemctl stop nginx
        certbot certonly --standalone --non-interactive --agree-tos -m admin@$MAIN_DOMAIN $DOMAINS
        systemctl start nginx
    fi

    # 6. Nginx Config
    log "⚙️ Настраиваю Nginx..."
    if [ -f "$NGINX_CONF_DIR/nginx.conf" ]; then
        mv "$NGINX_CONF_DIR/nginx.conf" "$NGINX_CONF_DIR/nginx.conf.bak.$(date +%s)"
    fi

    cat <<EOF > "$NGINX_CONF_DIR/nginx.conf"
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 4096; }

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 90s;
    client_max_body_size 32M;
    server_names_hash_bucket_size 128;
    server_tokens off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    
    upstream remnawave_panel_api { server 127.0.0.1:3000; }
    upstream remnawave_subscription_page { server 127.0.0.1:3010; }
    upstream remnawave_mini_app { server 127.0.0.1:3020; }
    upstream tinyauth_service { server 127.0.0.1:3002; }
    upstream remnawave_bot_unified { server 127.0.0.1:8080; }

    server {
        listen 80;
        server_name *.$MAIN_DOMAIN;
        return 301 https://\$host\$request_uri;
    }

    # TinyAuth
    server {
        listen 443 ssl;
        http2 on;
        server_name auth.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        location / {
            proxy_pass http://tinyauth_service;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }

    # Panel
    server {
        listen 443 ssl;
        http2 on;
        server_name panrem.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        
        location / {
            auth_request /auth_verify;
            error_page 401 = @auth_login;
            proxy_pass http://remnawave_panel_api;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
        location = /auth_verify {
            internal;
            proxy_pass http://tinyauth_service/api/auth/nginx;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header X-Original-URI \$request_uri;
        }
        location @auth_login {
            internal;
            return 302 https://auth.$MAIN_DOMAIN/login?redirect_uri=https://\$host\$request_uri;
        }
    }

    # Sub Page
    server {
        listen 443 ssl;
        http2 on;
        server_name subrem.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        location / {
            proxy_pass http://remnawave_subscription_page;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    # Hooks
    server {
        listen 443 ssl;
        http2 on;
        server_name hooks.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        location / {
            proxy_pass http://remnawave_bot_unified;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    # Mini App
    server {
        listen 443 ssl;
        http2 on;
        server_name miniapp.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        add_header X-Frame-Options "";
        root $MINIAPP_DIR;
        index index.html;
        location /miniapp/ {
            proxy_pass http://remnawave_bot_unified/miniapp/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
        location / { try_files \$uri \$uri/ /index.html; }
    }

    # API Bot
    server {
        listen 443 ssl;
        http2 on;
        server_name apibot.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        location / {
            proxy_pass http://remnawave_bot_unified;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }

    # Sub App (Redirect)
    server {
        listen 443 ssl;
        http2 on;
        server_name subapp.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        add_header X-Frame-Options "";
        
        location /myredirect/ {
            alias $MINIAPP_DIR/myredirect/;
            try_files \$uri \$uri/ /index.html;
        }
        location / {
            proxy_pass http://remnawave_mini_app;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF

    log "🔄 Перезагружаю Nginx..."
    run_cmd nginx -t && run_cmd systemctl reload nginx

    log "🚀 Запускаю Панель..."
    cd "$PANEL_DIR"
    run_cmd docker compose up -d

    echo -e "\n${C_GREEN}✅ ПАНЕЛЬ УСТАНОВЛЕНА!${C_RESET}"
    echo -e "Панель: https://panrem.$MAIN_DOMAIN"
    echo -e "TinyAuth: $TA_USER / (твой пароль)"
    wait_enter
}

# ============================================================ #
#                    ЛОГИКА УСТАНОВКИ НОДЫ                     #
# ============================================================ #
install_node_logic() {
    clear
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_CYAN}║               УСТАНОВКА НОДЫ REMNAWAVE                       ║${C_RESET}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    
    check_dependencies
    
    read -p "Введи URL Панели (например, https://panrem.domain.com): " PANEL_URL
    read -p "Введи Node Secret (из настроек узла в панели): " NODE_SECRET
    
    if [[ -z "$PANEL_URL" || -z "$NODE_SECRET" ]]; then error "Данные не могут быть пустыми."; fi

    log "📂 Создаю папку ноды..."
    run_cmd mkdir -p "$NODE_DIR"

    log "📝 Создаю docker-compose.yml для Ноды..."
    cat <<EOF > "$NODE_DIR/docker-compose.yml"
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    restart: always
    network_mode: host
    environment:
      - REMNAWAVE_PANEL_URL=$PANEL_URL
      - REMNAWAVE_NODE_SECRET=$NODE_SECRET
      # Опционально: SSL сертификаты, если нужны
      # - SSL_CERT_PATH=/etc/letsencrypt/live/domain/fullchain.pem
      # - SSL_KEY_PATH=/etc/letsencrypt/live/domain/privkey.pem
    volumes:
      # Если нужны сертификаты, раскомментируй:
      # - /etc/letsencrypt:/etc/letsencrypt:ro
      - remnanode-data:/app/data

volumes:
  remnanode-data:
EOF

    log "🚀 Запускаю Ноду..."
    cd "$NODE_DIR"
    run_cmd docker compose up -d

    echo -e "\n${C_GREEN}✅ НОДА ЗАПУЩЕНА!${C_RESET}"
    wait_enter
}

# ============================================================ #
#                    МЕНЮ УПРАВЛЕНИЯ                           #
# ============================================================ #

manage_panel_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}--- УПРАВЛЕНИЕ ПАНЕЛЬЮ ---${C_RESET}"
        echo "1. 📜 Смотреть логи (все)"
        echo "2. 🔄 Перезагрузить Панель"
        echo "3. ⬆️  Обновить Панель (Pull & Up)"
        echo "4. 🛑 Остановить Панель"
        echo "b. 🔙 Назад"
        read -p "Выбор: " choice
        case $choice in
            1) cd "$PANEL_DIR" && docker compose logs -f ;;
            2) cd "$PANEL_DIR" && docker compose restart && echo "✅ Перезагружено." && sleep 2 ;;
            3) cd "$PANEL_DIR" && docker compose pull && docker compose up -d && echo "✅ Обновлено." && sleep 2 ;;
            4) cd "$PANEL_DIR" && docker compose down && echo "🛑 Остановлено." && sleep 2 ;;
            [bB]) break ;;
            *) ;;
        esac
    done
}

manage_node_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}--- УПРАВЛЕНИЕ НОДОЙ ---${C_RESET}"
        echo "1. 📜 Смотреть логи"
        echo "2. 🔄 Перезагрузить Ноду"
        echo "3. ⬆️  Обновить Ноду"
        echo "4. 🛑 Остановить Ноду"
        echo "b. 🔙 Назад"
        read -p "Выбор: " choice
        case $choice in
            1) cd "$NODE_DIR" && docker compose logs -f ;;
            2) cd "$NODE_DIR" && docker compose restart && echo "✅ Перезагружено." && sleep 2 ;;
            3) cd "$NODE_DIR" && docker compose pull && docker compose up -d && echo "✅ Обновлено." && sleep 2 ;;
            4) cd "$NODE_DIR" && docker compose down && echo "🛑 Остановлено." && sleep 2 ;;
            [bB]) break ;;
            *) ;;
        esac
    done
}

uninstall_menu() {
    echo -e "${C_RED}⚠️  ВНИМАНИЕ! ЭТО УДАЛИТ ВСЕ ДАННЫЕ!${C_RESET}"
    read -p "Ты уверен? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        echo "Удаляю Панель..."
        if [ -d "$PANEL_DIR" ]; then cd "$PANEL_DIR" && docker compose down -v; rm -rf "$PANEL_DIR"; fi
        echo "Удаляю Ноду..."
        if [ -d "$NODE_DIR" ]; then cd "$NODE_DIR" && docker compose down -v; rm -rf "$NODE_DIR"; fi
        echo "✅ Всё удалено."
        wait_enter
    fi
}

# ============================================================ #
#                    ГЛАВНОЕ МЕНЮ МОДУЛЯ                       #
# ============================================================ #
main_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_CYAN}║          REMNAWAVE MANAGER (RESHALA EDITION)                 ║${C_RESET}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
        echo ""
        echo "   1. 💿 Установить Панель (High-Load + TinyAuth)"
        echo "   2. 📡 Установить Ноду (Remnanode)"
        echo "   -------------------------------------------"
        echo "   3. 🛠  Управление Панелью (Логи, Рестарт, Обнова)"
        echo "   4. 🛠  Управление Нодой (Логи, Рестарт, Обнова)"
        echo "   -------------------------------------------"
        echo "   5. 🗑  Удалить всё к чертям"
        echo "   b. 🔙 Выход в главное меню Решалы"
        echo ""
        read -p "Твой выбор: " choice
        
        case $choice in
            1) install_panel_logic ;;
            2) install_node_logic ;;
            3) 
                if [ -d "$PANEL_DIR" ]; then manage_panel_menu; else echo "❌ Панель не установлена."; sleep 2; fi 
                ;;
            4) 
                if [ -d "$NODE_DIR" ]; then manage_node_menu; else echo "❌ Нода не установлена."; sleep 2; fi 
                ;;
            5) uninstall_menu ;;
            [bB]) break ;;
            *) echo "Не тупи."; sleep 1 ;;
        esac
    done
}

# Запуск
main_menu