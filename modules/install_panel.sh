#!/bin/bash
# ============================================================ #
# ==     МОДУЛЬ УСТАНОВКИ REMNAWAVE (RESHALA EDITION)       ==
# ============================================================ #

# --- Цвета (дублируем для автономности) ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Константы ---
INSTALL_DIR="/opt/remnawave"
LOG_FILE="/var/log/reshala_panel.log"

# --- Хелперы ---
log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE" >/dev/null
}

msg_info() { printf "%b\n" "${C_CYAN}ℹ️  $1${C_RESET}"; log "INFO: $1"; }
msg_ok() { printf "%b\n" "${C_GREEN}✅ $1${C_RESET}"; log "OK: $1"; }
msg_warn() { printf "%b\n" "${C_YELLOW}⚠️  $1${C_RESET}"; log "WARN: $1"; }
msg_err() { printf "%b\n" "${C_RED}❌ $1${C_RESET}"; log "ERROR: $1"; exit 1; }

run_cmd() {
    if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# --- Генераторы ---
generate_pass() { < /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24; }
generate_user() { < /dev/urandom tr -dc 'a-z' | head -c 8; }

# ============================================================ #
#                    ПРОВЕРКИ И ЗАВИСИМОСТИ                    #
# ============================================================ #

check_dependencies() {
    msg_info "Проверяю, есть ли у тебя нужные инструменты..."
    
    local deps=(curl wget jq openssl git cron)
    local install_needed=0

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            install_needed=1
            break
        fi
    done

    if [ $install_needed -eq 1 ]; then
        msg_warn "Чего-то не хватает. Ща доставим..."
        run_cmd apt-get update -y
        run_cmd apt-get install -y "${deps[@]}" ca-certificates gnupg lsb-release ufw
    fi

    # Docker
    if ! command -v docker &> /dev/null; then
        msg_warn "Docker не найден. Ставим эту махину..."
        curl -fsSL https://get.docker.com | sh
        run_cmd systemctl enable --now docker
    fi
    
    # Certbot
    if ! command -v certbot &> /dev/null; then
        msg_warn "Certbot нужен для HTTPS. Гружу..."
        run_cmd apt-get install -y certbot python3-certbot-dns-cloudflare
    fi

    msg_ok "Все инструменты на базе."
}

check_domain_ip() {
    local domain="$1"
    local strict="$2" # true = ошибка если не совпадает, false = варнинг
    
    msg_info "Пробиваю домен $domain..."
    local domain_ip=$(dig +short A "$domain" | head -n 1)
    local server_ip=$(curl -s -4 ifconfig.me)

    if [ -z "$domain_ip" ]; then
        msg_err "Домен $domain вообще никуда не ведет. Ты DNS настроил, дядя?"
    fi

    if [ "$domain_ip" != "$server_ip" ]; then
        # Проверка на Cloudflare
        local is_cf=$(curl -s https://www.cloudflare.com/ips-v4 | grep -f <(echo "$domain_ip") || echo "no")
        
        if [[ "$is_cf" != "no" ]]; then
             msg_warn "Домен за Cloudflare (Proxy). Для панели ок, для ноды (self-steal) нужно 'DNS Only'!"
             if [ "$strict" == "true" ]; then
                read -p "Ты уверен, что хочешь продолжить с проксированием? (y/n): " confirm
                [[ "$confirm" != "y" ]] && msg_err "Отмена. Иди настраивай DNS."
             fi
        else
            msg_warn "IP домена ($domain_ip) не совпадает с IP сервера ($server_ip)."
            read -p "Всё равно продолжить? (y/n): " confirm
            [[ "$confirm" != "y" ]] && msg_err "Отмена."
        fi
    else
        msg_ok "Домен смотрит куда надо."
    fi
}

# ============================================================ #
#                    СЕРТИФИКАТЫ (ГЕМОРРОЙ)                    #
# ============================================================ #

issue_certs() {
    local domains=("$@")
    local email=""
    
    echo ""
    msg_info "Время шифроваться. Как будем получать сертификаты?"
    echo "   1. Cloudflare API (Если домен на CF, поддерживает Wildcard)"
    echo "   2. Let's Encrypt (Классика, нужен 80 порт)"
    read -p "Выбор (1/2): " method

    if [ "$method" == "1" ]; then
        read -p "Введи Email от Cloudflare: " cf_email
        read -p "Введи Global API Key (или Token): " cf_key
        
        mkdir -p ~/.secrets/certbot
        echo "dns_cloudflare_email = $cf_email" > ~/.secrets/certbot/cloudflare.ini
        echo "dns_cloudflare_api_key = $cf_key" >> ~/.secrets/certbot/cloudflare.ini
        chmod 600 ~/.secrets/certbot/cloudflare.ini

        for domain in "${domains[@]}"; do
            msg_info "Генерирую Wildcard для $domain через Cloudflare..."
            # Берем base domain
            local base_domain=$(echo "$domain" | awk -F'.' '{print $(NF-1)"."$NF}')
            certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 -d "$base_domain" -d "*.$base_domain" \
                --email "$cf_email" --agree-tos --non-interactive --key-type ecdsa
        done

    elif [ "$method" == "2" ]; then
        read -p "Введи Email для Let's Encrypt: " le_email
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
#                    API МАГИЯ (АВТОНАСТРОЙКА)                 #
# ============================================================ #

api_req() {
    local method=$1
    local url=$2
    local token=$3
    local data=$4
    
    local auth_header=""
    [ -n "$token" ] && auth_header="Authorization: Bearer $token"

    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" -H "$auth_header" -H "Content-Type: application/json" -d "$data"
    else
        curl -s -X "$method" "$url" -H "$auth_header" -H "Content-Type: application/json"
    fi
}

wait_for_panel() {
    msg_info "Жду, пока панель проснется (это может занять минуту)..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -s "http://127.0.0.1:3000/api/auth/register" >/dev/null; then
            return 0
        fi
        printf "."
        sleep 5
        ((retries--))
    done
    echo ""
    msg_err "Панель не поднялась. Чекни логи: docker compose logs -f"
}

# ============================================================ #
#                    УСТАНОВКА ПАНЕЛИ + НОДЫ                   #
# ============================================================ #

install_full() {
    msg_info "Начинаем полную установку (Панель + Нода)..."

    # 1. Сбор данных
    read -p "Введи домен ПАНЕЛИ (panel.domain.com): " DOMAIN_PANEL
    check_domain_ip "$DOMAIN_PANEL" "false"
    
    read -p "Введи домен ПОДПИСКИ (sub.domain.com): " DOMAIN_SUB
    check_domain_ip "$DOMAIN_SUB" "false"
    
    read -p "Введи домен НОДЫ (node.domain.com) [Self-Steal]: " DOMAIN_NODE
    check_domain_ip "$DOMAIN_NODE" "true"

    # 2. Сертификаты
    issue_certs "$DOMAIN_PANEL" "$DOMAIN_SUB" "$DOMAIN_NODE"

    # 3. Генерация паролей
    local P_USER=$(generate_user)
    local P_PASS=$(generate_pass)
    local JWT_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
    local COOKIE_1=$(generate_user)
    local COOKIE_2=$(generate_user)

    # 4. Создание папок и конфигов
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || msg_err "Не могу зайти в $INSTALL_DIR"

    # .env
    cat > .env <<EOL
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"
REDIS_HOST=remnawave-redis
REDIS_PORT=6379
JWT_AUTH_SECRET=$JWT_SECRET
JWT_API_TOKENS_SECRET=$JWT_SECRET
JWT_AUTH_LIFETIME=168
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
FRONT_END_DOMAIN=$DOMAIN_PANEL
SUB_PUBLIC_DOMAIN=$DOMAIN_SUB
IS_DOCS_ENABLED=false
METRICS_USER=$(generate_user)
METRICS_PASS=$(generate_pass)
HWID_DEVICE_LIMIT_ENABLED=false
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOL

    # docker-compose.yml
    # Определяем пути к сертификатам (учитываем Wildcard)
    local CERT_PATH_PANEL="/etc/letsencrypt/live/$DOMAIN_PANEL"
    [ ! -d "$CERT_PATH_PANEL" ] && CERT_PATH_PANEL="/etc/letsencrypt/live/$(echo $DOMAIN_PANEL | awk -F'.' '{print $(NF-1)"."$NF}')"
    
    local CERT_PATH_SUB="/etc/letsencrypt/live/$DOMAIN_SUB"
    [ ! -d "$CERT_PATH_SUB" ] && CERT_PATH_SUB="/etc/letsencrypt/live/$(echo $DOMAIN_SUB | awk -F'.' '{print $(NF-1)"."$NF}')"
    
    local CERT_PATH_NODE="/etc/letsencrypt/live/$DOMAIN_NODE"
    [ ! -d "$CERT_PATH_NODE" ] && CERT_PATH_NODE="/etc/letsencrypt/live/$(echo $DOMAIN_NODE | awk -F'.' '{print $(NF-1)"."$NF}')"

    cat > docker-compose.yml <<EOL
services:
  remnawave-db:
    image: postgres:16-alpine
    restart: always
    env_file: .env
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  remnawave-redis:
    image: redis:alpine
    restart: always
    volumes:
      - remnawave-redis-data:/data

  remnawave:
    image: remnawave/backend:latest
    restart: always
    env_file: .env
    depends_on:
      remnawave-db:
        condition: service_healthy
    ports:
      - "127.0.0.1:3000:3000"

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
    ports:
      - "127.0.0.1:3010:3010"

  remnanode:
    image: remnawave/node:latest
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=PLACEHOLDER_KEY
    volumes:
      - /dev/shm:/dev/shm:rw

  remnawave-nginx:
    image: nginx:alpine
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /var/www/html:/var/www/html:ro
      - $CERT_PATH_PANEL:/etc/nginx/ssl/panel:ro
      - $CERT_PATH_SUB:/etc/nginx/ssl/sub:ro
      - $CERT_PATH_NODE:/etc/nginx/ssl/node:ro

volumes:
  remnawave-db-data:
  remnawave-redis-data:
EOL

    # nginx.conf
    cat > nginx.conf <<EOL
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}
# Секретные куки для защиты панели
map \$http_cookie \$auth_cookie {
    default 0;
    "~*${COOKIE_1}=${COOKIE_2}" 1;
}
map \$arg_${COOKIE_1} \$auth_query {
    default 0;
    "${COOKIE_2}" 1;
}
map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}
map \$arg_${COOKIE_1} \$set_cookie_header {
    "${COOKIE_2}" "${COOKIE_1}=${COOKIE_2}; Path=/; HttpOnly; Secure; Max-Age=31536000";
    default "";
}

server {
    server_name $DOMAIN_PANEL;
    listen 443 ssl;
    http2 on;
    ssl_certificate /etc/nginx/ssl/panel/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/panel/privkey.pem;
    add_header Set-Cookie \$set_cookie_header;

    location / {
        if (\$authorized = 0) { return 444; }
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

server {
    server_name $DOMAIN_SUB;
    listen 443 ssl;
    http2 on;
    ssl_certificate /etc/nginx/ssl/sub/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/sub/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3010;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

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

    # 5. Запуск
    msg_info "Запускаю контейнеры..."
    run_cmd docker compose up -d
    
    # 6. Автонастройка через API
    wait_for_panel
    
    msg_info "Регистрирую админа..."
    local REG_RESP=$(api_req "POST" "http://127.0.0.1:3000/api/auth/register" "" "{\"username\":\"$P_USER\",\"password\":\"$P_PASS\"}")
    local TOKEN=$(echo $REG_RESP | jq -r '.response.accessToken')
    
    if [ "$TOKEN" == "null" ]; then msg_err "Не удалось зарегать админа. Ответ: $REG_RESP"; fi
    msg_ok "Админ создан!"

    msg_info "Генерирую ключи..."
    local PUB_KEY_RESP=$(api_req "GET" "http://127.0.0.1:3000/api/keygen" "$TOKEN")
    local PUB_KEY=$(echo $PUB_KEY_RESP | jq -r '.response.pubKey')
    
    local XRAY_KEYS=$(api_req "GET" "http://127.0.0.1:3000/api/system/tools/x25519/generate" "$TOKEN")
    local PRIV_KEY=$(echo $XRAY_KEYS | jq -r '.response.keypairs[0].privateKey')

    # Обновляем ключ в docker-compose
    sed -i "s|PLACEHOLDER_KEY|$PUB_KEY|g" docker-compose.yml
    run_cmd docker compose up -d # Перезапуск для применения ключа

    msg_info "Создаю конфиг и ноду..."
    # Удаляем дефолт
    local DEF_UUID=$(api_req "GET" "http://127.0.0.1:3000/api/config-profiles" "$TOKEN" | jq -r '.response.configProfiles[] | select(.name=="Default-Profile") | .uuid')
    [ -n "$DEF_UUID" ] && api_req "DELETE" "http://127.0.0.1:3000/api/config-profiles/$DEF_UUID" "$TOKEN"

    # Создаем профиль
    local SHORT_ID=$(openssl rand -hex 8)
    local CONF_JSON=$(jq -n \
        --arg name "StealConfig" \
        --arg domain "$DOMAIN_NODE" \
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

    # Создаем ноду
    local NODE_JSON=$(jq -n \
        --arg conf "$CONF_UUID" \
        --arg inb "$INB_UUID" \
        --arg addr "$DOMAIN_NODE" \
        '{
            name: "LocalNode", address: $addr, port: 2222,
            configProfile: {activeConfigProfileUuid: $conf, activeInbounds: [$inb]}
        }')
    api_req "POST" "http://127.0.0.1:3000/api/nodes" "$TOKEN" "$NODE_JSON"

    # Создаем хост
    local HOST_JSON=$(jq -n \
        --arg conf "$CONF_UUID" \
        --arg inb "$INB_UUID" \
        --arg addr "$DOMAIN_NODE" \
        '{
            remark: "Steal", address: $addr, port: 443, sni: $addr,
            inbound: {configProfileUuid: $conf, configProfileInboundUuid: $inb}
        }')
    api_req "POST" "http://127.0.0.1:3000/api/hosts" "$TOKEN" "$HOST_JSON"

    # Обновляем Squad (чтобы подписка работала)
    local SQUAD_UUID=$(api_req "GET" "http://127.0.0.1:3000/api/internal-squads" "$TOKEN" | jq -r '.response.internalSquads[0].uuid')
    local SQUAD_JSON=$(jq -n --arg uuid "$SQUAD_UUID" --arg inb "$INB_UUID" '{uuid: $uuid, inbounds: [$inb]}')
    api_req "PATCH" "http://127.0.0.1:3000/api/internal-squads" "$TOKEN" "$SQUAD_JSON"

    # Маскировка
    msg_info "Качаю маскировочный сайт..."
    mkdir -p /var/www/html
    wget -q -O /tmp/site.zip https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip
    unzip -o -q /tmp/site.zip -d /tmp/
    cp -r /tmp/simple-web-templates-main/Crypto/* /var/www/html/
    rm -rf /tmp/site.zip /tmp/simple-web-templates-main

    # Финал
    echo ""
    msg_ok "УСТАНОВКА ЗАВЕРШЕНА!"
    echo "----------------------------------------------------"
    echo "🔗 Ссылка: https://$DOMAIN_PANEL/auth/login?${COOKIE_1}=${COOKIE_2}"
    echo "👤 Логин:  $P_USER"
    echo "🔑 Пароль: $P_PASS"
    echo "----------------------------------------------------"
    echo "Сохрани это, я два раза повторять не буду."
}

# ============================================================ #
#                    МЕНЮ МОДУЛЯ                               #
# ============================================================ #

show_menu() {
    clear
    printf "%b\n" "${C_CYAN}--- УСТАНОВКА REMNAWAVE (RESHALA STYLE) ---${C_RESET}"
    echo "1. Влупить всё сразу (Панель + Нода + Автонастройка)"
    echo "2. Только Панель (если ноды будут отдельно)"
    echo "3. Только Нода (подключить к существующей панели)"
    echo "0. Назад"
    echo "---------------------------------------------------"
    read -p "Выбор: " choice

    case $choice in
        1)
            check_dependencies
            install_full
            ;;
        2)
            msg_warn "Этот режим пока в разработке. Юзай пункт 1, не выпендривайся."
            ;;
        3)
            msg_warn "Для установки ноды запусти этот скрипт на чистом сервере ноды."
            # Тут можно добавить логику install_node из оригинала, если нужно
            ;;
        0)
            exit 0
            ;;
        *)
            msg_err "Ты промахнулся."
            ;;
    esac
}

# Запуск
show_menu