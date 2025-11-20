#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ REMNAWAVE: РАЗДЕЛЬНАЯ СБОРКА (PRO EDITION)    ==
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

get_panel_token() {
    # Пытаемся найти токен или логинимся
    if [ -f "$INSTALL_DIR/token" ]; then
        cat "$INSTALL_DIR/token"
    else
        # Если токена нет, надо бы его получить, но тут нужна интерактивность.
        # Для упрощения считаем, что мы только что поставили панель или юзер знает креды.
        # В рамках скрипта "Добавить ноду" мы спросим креды.
        echo ""
    fi
}

# ============================================================ #
#                    ЧАСТЬ 1: УСТАНОВКА ПАНЕЛИ                 #
# ============================================================ #

install_panel_only() {
    msg_info "Ставим ПАНЕЛЬ (Master Server)..."
    
    read -p "Домен ПАНЕЛИ (panel.domain.com): " DOMAIN_PANEL
    check_domain_ip "$DOMAIN_PANEL" "false"
    
    read -p "Домен ПОДПИСКИ (sub.domain.com): " DOMAIN_SUB
    check_domain_ip "$DOMAIN_SUB" "false"

    issue_certs "$DOMAIN_PANEL" "$DOMAIN_SUB"

    local P_USER=$(generate_user)
    local P_PASS=$(generate_pass)
    local JWT_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
    local COOKIE_1=$(generate_user)
    local COOKIE_2=$(generate_user)

    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

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

    # Пути к сертификатам
    local CERT_PATH_PANEL="/etc/letsencrypt/live/$DOMAIN_PANEL"
    [ ! -d "$CERT_PATH_PANEL" ] && CERT_PATH_PANEL="/etc/letsencrypt/live/$(echo $DOMAIN_PANEL | awk -F'.' '{print $(NF-1)"."$NF}')"
    local CERT_PATH_SUB="/etc/letsencrypt/live/$DOMAIN_SUB"
    [ ! -d "$CERT_PATH_SUB" ] && CERT_PATH_SUB="/etc/letsencrypt/live/$(echo $DOMAIN_SUB | awk -F'.' '{print $(NF-1)"."$NF}')"

    # docker-compose.yml (ТОЛЬКО ПАНЕЛЬ)
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

  remnawave-nginx:
    image: nginx:alpine
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - $CERT_PATH_PANEL:/etc/nginx/ssl/panel:ro
      - $CERT_PATH_SUB:/etc/nginx/ssl/sub:ro

volumes:
  remnawave-db-data:
  remnawave-redis-data:
EOL

    # nginx.conf
    cat > nginx.conf <<EOL
map \$http_upgrade \$connection_upgrade { default upgrade; "" close; }
map \$http_cookie \$auth_cookie { default 0; "~*${COOKIE_1}=${COOKIE_2}" 1; }
map \$arg_${COOKIE_1} \$auth_query { default 0; "${COOKIE_2}" 1; }
map "\$auth_cookie\$auth_query" \$authorized { "~1" 1; default 0; }
map \$arg_${COOKIE_1} \$set_cookie_header { "${COOKIE_2}" "${COOKIE_1}=${COOKIE_2}; Path=/; HttpOnly; Secure; Max-Age=31536000"; default ""; }

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
EOL

    msg_info "Запускаю панель..."
    run_cmd docker compose up -d

    # Ждем старта
    msg_info "Жду API..."
    sleep 15
    
    # Регистрация админа
    msg_info "Регаю админа..."
    local REG_RESP=$(api_req "POST" "http://127.0.0.1:3000/api/auth/register" "" "{\"username\":\"$P_USER\",\"password\":\"$P_PASS\"}")
    local TOKEN=$(echo $REG_RESP | jq -r '.response.accessToken')
    
    if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
        msg_err "Ошибка регистрации. Ответ: $REG_RESP"
    fi
    
    # Сохраняем токен
    echo "$TOKEN" > "$INSTALL_DIR/token"

    # Генерируем ключи панели
    msg_info "Генерирую ключи панели..."
    local PUB_KEY_RESP=$(api_req "GET" "http://127.0.0.1:3000/api/keygen" "$TOKEN")
    local PUB_KEY=$(echo $PUB_KEY_RESP | jq -r '.response.pubKey')
    
    # Удаляем дефолтный профиль
    local DEF_UUID=$(api_req "GET" "http://127.0.0.1:3000/api/config-profiles" "$TOKEN" | jq -r '.response.configProfiles[] | select(.name=="Default-Profile") | .uuid')
    [ -n "$DEF_UUID" ] && api_req "DELETE" "http://127.0.0.1:3000/api/config-profiles/$DEF_UUID" "$TOKEN"

    echo ""
    msg_ok "ПАНЕЛЬ УСТАНОВЛЕНА!"
    echo "----------------------------------------------------"
    echo "🔗 Вход: https://$DOMAIN_PANEL/auth/login?${COOKIE_1}=${COOKIE_2}"
    echo "👤 Логин:  $P_USER"
    echo "🔑 Пароль: $P_PASS"
    echo "----------------------------------------------------"
    echo "Теперь иди на сервер НОДЫ и ставь ноду. Но сначала..."
    echo "Запусти пункт 'Добавить НОДУ' в этом меню, чтобы получить ключи!"
}

# ============================================================ #
#                    ЧАСТЬ 2: ДОБАВЛЕНИЕ НОДЫ (НА ПАНЕЛИ)      #
# ============================================================ #

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

# ============================================================ #
#                    МЕНЮ                                      #
# ============================================================ #

show_menu() {
    clear
    printf "%b\n" "${C_CYAN}--- REMNAWAVE: РАЗДЕЛЬНАЯ УСТАНОВКА ---${C_RESET}"
    echo "1. 🔥 Установить ПАНЕЛЬ (Master Server)"
    echo "2. ➕ Добавить НОДУ (Выполнять на ПАНЕЛИ)"
    echo "3. 🧱 Установить НОДУ (Выполнять на НОДЕ)"
    echo "0. Назад"
    echo "---------------------------------------------------"
    read -p "Твой выбор: " choice

    case $choice in
        1) check_dependencies; install_panel_only ;;
        2) check_dependencies; add_node_on_panel ;;
        3) check_dependencies; install_node_only ;;
        0) exit 0 ;;
        *) msg_err "Глаза разуй, нет такого пункта." ;;
    esac
}

show_menu