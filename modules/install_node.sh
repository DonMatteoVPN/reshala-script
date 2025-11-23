#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ УСТАНОВКИ REMNAWAVE NODE (PRODUCTION V3)      ==
# ==      FIXED FUNCTION ORDER & API LOGIC FROM SOURCE      ==
# ============================================================ #

# --- 1. КОНФИГУРАЦИЯ И ПЕРЕМЕННЫЕ ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

INSTALL_DIR="/opt/remnawave-node"
CERT_DIR="/root/certs_node"
SITE_DIR="/var/www/html"
CRON_FILE="/etc/cron.d/remnawave-node"
ROTATE_SCRIPT="/usr/local/bin/reshala-rotate-site"
SMART_RENEW_SCRIPT="/usr/local/bin/reshala-smart-renew"

# Переменные, которые будут заполнены
API_URL=""
API_TOKEN=""
NODE_NAME=""
NODE_DOMAIN=""
NODE_SECRET=""
PROFILE_ID=""
CERT_STRATEGY=""
PANEL_IP=""
PANEL_PORT=""
PANEL_USER=""
PANEL_PASS=""
CF_TOKEN=""
CF_EMAIL=""

# --- 2. УТИЛИТЫ ---
run_cmd() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
safe_read() { read -e -p "$1" -i "$2" result; echo "${result:-$2}"; }

install_base_tools() {
    echo "🔧 Установка базовых утилит (curl, jq)..."
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v jq &>/dev/null; then apt-get update -qq && apt-get install -y -qq jq curl wget &>/dev/null; fi
}

install_full_tools() {
    echo "🔧 Установка полных зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq unzip socat git cron sshpass ufw certbot openssl &>/dev/null
    
    if ! command -v docker &> /dev/null; then
        echo "🐳 Установка Docker..."
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    fi
}

# ============================================================ #
#                3. ФУНКЦИИ API (REMNAWAVE)                    #
# ============================================================ #

step_auth() {
    clear
    printf "%b\n" "${C_CYAN}🚀 НАСТРОЙКА НОДЫ (API MODE)${C_RESET}"
    echo ""
    API_URL=$(safe_read "🔗 URL Панели (напр. https://panel.domain.com): " "")
    # Убираем слеш на конце и возможный /api (добавим сами где надо)
    API_URL=${API_URL%/}
    API_URL=${API_URL%/api}
    
    echo ""
    echo "1. Вход по Логину/Паролю"
    echo "2. Вход по Токену (Bearer)"
    local auth_type=$(safe_read "Выбор: " "1")

    if [[ "$auth_type" == "2" ]]; then
        echo "Вставь токен:"
        read -r API_TOKEN
        # Проверка токена
        local CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_TOKEN" "${API_URL}/api/users")
        if [[ "$CODE" != "200" ]]; then echo "❌ Токен невалиден (Код $CODE)."; exit 1; fi
    else
        local USER=$(safe_read "Login: " "admin")
        read -s -p "Password: " PASS; echo ""
        
        # Запрос токена
        local RESPONSE=$(curl -s -L -X POST "${API_URL}/api/auth/login" \
            -H "Content-Type: application/json" \
            -d "{\"username\": \"$USER\", \"password\": \"$PASS\"}")
            
        if [[ "$RESPONSE" == *"<html"* ]]; then
            echo "❌ Ошибка: Сервер вернул HTML. Проверь URL."
            exit 1
        fi
        
        API_TOKEN=$(echo "$RESPONSE" | jq -r '.accessToken')
        if [[ "$API_TOKEN" == "null" || -z "$API_TOKEN" ]]; then
            echo "❌ Ошибка авторизации: $RESPONSE"
            exit 1
        fi
        echo "✅ Авторизация успешна."
    fi
}

step_create_profile() {
    echo ""
    NODE_NAME=$(safe_read "🏷️ Имя Ноды (English): " "Node_$(hostname)")
    NODE_DOMAIN=$(safe_read "🌐 Домен Ноды (tr1.site.com): " "")
    [[ -z "$NODE_DOMAIN" ]] && { echo "❌ Домен обязателен"; exit 1; }

    echo "📝 Создаю профиль..."
    local PROFILE_JSON=$(cat <<EOF
{
  "name": "${NODE_NAME}_WS_TLS",
  "type": "xray_json",
  "content": {
    "log": { "loglevel": "warning" },
    "dns": { "servers": ["https://dns.google/dns-query", "https://1.1.1.1/dns-query"], "queryStrategy": "UseIPv4" },
    "inbounds": [
      {
        "tag": "VLESS-WS-TLS",
        "port": 443,
        "protocol": "vless",
        "settings": {
          "clients": [],
          "decryption": "none",
          "fallbacks": [{ "dest": 8080 }]
        },
        "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
        "streamSettings": {
          "network": "ws",
          "security": "tls",
          "tlsSettings": {
            "serverName": "${NODE_DOMAIN}",
            "minVersion": "1.2",
            "maxVersion": "1.3",
            "certificates": [{ "certificateFile": "/cert/fullchain.pem", "keyFile": "/cert/privkey.pem" }]
          },
          "wsSettings": { "path": "/" }
        }
      }
    ],
    "outbounds": [
      { "tag": "DIRECT", "protocol": "freedom" },
      { "tag": "BLOCK", "protocol": "blackhole" }
    ],
    "routing": {
      "rules": [
        { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "BLOCK" },
        { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "BLOCK" }
      ]
    }
  }
}
EOF
)
    local RESPONSE=$(curl -s -X POST "${API_URL}/api/configurations" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PROFILE_JSON")
    
    PROFILE_ID=$(echo "$RESPONSE" | jq -r '.id')
    if [[ "$PROFILE_ID" == "null" ]]; then echo "❌ Ошибка создания профиля: $RESPONSE"; exit 1; fi
    echo "✅ Профиль создан ID: $PROFILE_ID"
}

step_create_node() {
    echo "📝 Создаю хост..."
    local NODE_JSON="{\"name\": \"${NODE_NAME}\", \"address\": \"${NODE_DOMAIN}\", \"configurationId\": \"${PROFILE_ID}\"}"
    
    # Пробуем /api/hosts (новое API)
    local RESPONSE=$(curl -s -X POST "${API_URL}/api/hosts" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$NODE_JSON")
        
    NODE_SECRET=$(echo "$RESPONSE" | jq -r '.secretKey')
    
    # Если не вышло, пробуем /api/nodes (старое API)
    if [[ "$NODE_SECRET" == "null" ]]; then
        RESPONSE=$(curl -s -X POST "${API_URL}/api/nodes" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$NODE_JSON")
        NODE_SECRET=$(echo "$RESPONSE" | jq -r '.secretKey')
    fi

    if [[ "$NODE_SECRET" == "null" ]]; then echo "❌ Ошибка создания ноды: $RESPONSE"; exit 1; fi
    echo "✅ Нода создана. SECRET_KEY получен."
}

# ============================================================ #
#                4. НАСТРОЙКА СЕРВЕРА                          #
# ============================================================ #

step_certificates() {
    echo ""
    echo "[ СЕРТИФИКАТЫ ]"
    echo "1. Cloudflare API"
    echo "2. Копия с Панели (SSH)"
    echo "3. Certbot Standalone"
    CERT_STRATEGY=$(safe_read "Выбор: " "1")
    mkdir -p "$CERT_DIR"

    case "$CERT_STRATEGY" in
        1) # CF
            CF_TOKEN=$(safe_read "CF Token: " "")
            CF_EMAIL=$(safe_read "CF Email: " "")
            if [ ! -d "/root/.acme.sh" ]; then curl https://get.acme.sh | sh -s email="$CF_EMAIL" >/dev/null 2>&1; fi
            export CF_Token="$CF_TOKEN"; export CF_Email="$CF_EMAIL"
            /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$NODE_DOMAIN" -d "*.$NODE_DOMAIN" --force
            /root/.acme.sh/acme.sh --install-cert -d "$NODE_DOMAIN" --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode"
            ;;
        
        2) # Panel Copy
            # Определяем IP из URL если не задан
            local DEF_IP=$(echo "$API_URL" | awk -F/ '{print $3}' | cut -d: -f1)
            PANEL_IP=$(safe_read "IP Панели: " "$DEF_IP")
            
            # Проверка локальности
            if [[ "$PANEL_IP" == "127.0.0.1" || "$PANEL_IP" == "localhost" || "$PANEL_IP" == "$(hostname -I | awk '{print $1}')" ]]; then
                echo "✅ Локальный сервер. Копирую напрямую."
                # Ищем
                local P=$(ls -d /etc/letsencrypt/live/* 2>/dev/null | grep "$NODE_DOMAIN" | head -n 1)
                if [[ -z "$P" ]]; then P=$(ls -d /root/.acme.sh/${NODE_DOMAIN}* 2>/dev/null | head -n 1); fi
                
                if [[ -n "$P" ]]; then
                    cp -L "$P/fullchain.pem" "$CERT_DIR/" || cp -L "$P/fullchain.cer" "$CERT_DIR/fullchain.pem"
                    cp -L "$P/privkey.pem" "$CERT_DIR/" || cp -L "$P/"*key* "$CERT_DIR/privkey.pem"
                else
                    echo "❌ Не нашел сертификат локально. Закинь файлы в $CERT_DIR вручную."
                fi
            else
                PANEL_PORT=$(safe_read "SSH Port: " "22")
                read -s -p "SSH Pass: " PANEL_PASS; echo ""
                
                echo "🔍 Ищу сертификаты на $PANEL_IP..."
                # Умный поиск через SSH
                local REMOTE_DIR
                REMOTE_DIR=$(sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -p "$PANEL_PORT" root@"$PANEL_IP" "ls -d /etc/letsencrypt/live/*${NODE_DOMAIN}* /root/.acme.sh/*${NODE_DOMAIN}* 2>/dev/null" | head -n 1)
                
                if [[ -n "$REMOTE_DIR" ]]; then
                    echo "✅ Нашел: $REMOTE_DIR"
                    sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "root@$PANEL_IP:$REMOTE_DIR/fullchain.*" "$CERT_DIR/fullchain.pem"
                    sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "root@$PANEL_IP:$REMOTE_DIR/*key*" "$CERT_DIR/privkey.pem"
                else
                    echo "❌ Сертификат для $NODE_DOMAIN не найден на панели."
                    echo "Введи полный путь вручную:"
                    read -e MAN_PATH
                    sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "root@$PANEL_IP:$MAN_PATH/fullchain.*" "$CERT_DIR/fullchain.pem"
                    sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "root@$PANEL_IP:$MAN_PATH/*key*" "$CERT_DIR/privkey.pem"
                fi
            fi
            ;;
            
        3) # Certbot
            echo "🆕 Выпуск Certbot..."
            ufw allow 80/tcp >/dev/null
            certbot certonly --standalone -d "$NODE_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
            cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
            cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
            ufw delete allow 80/tcp >/dev/null
            ;;
    esac
    
    chmod 644 "$CERT_DIR/"*
}

step_system_setup() {
    echo "🛡️ Настройка Firewall..."
    if ! command -v ufw &>/dev/null; then apt-get install -y ufw >/dev/null; fi
    ufw allow 22/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow 2222/tcp >/dev/null
    ufw delete allow 80/tcp >/dev/null
    if ! ufw status | grep -q "active"; then echo "y" | ufw enable >/dev/null; else ufw reload >/dev/null; fi
}

step_deploy() {
    echo "🚀 Разворачиваю Docker..."
    mkdir -p "$INSTALL_DIR"
    
    # 1. Сайт-заглушка
    cat << 'EOF' > "$ROTATE_SCRIPT"
#!/bin/bash
SITE_DIR="/var/www/html"; TEMP_DIR="/tmp/website_template"
URLS=("https://www.free-css.com/assets/files/free-css-templates/download/page296/healet.zip" "https://www.free-css.com/assets/files/free-css-templates/download/page296/carvilla.zip")
RANDOM_URL=${URLS[$RANDOM % ${#URLS[@]}]}
rm -rf "$TEMP_DIR" "$SITE_DIR"/*; mkdir -p "$TEMP_DIR" "$SITE_DIR"
wget -q -O "$TEMP_DIR/template.zip" "$RANDOM_URL"; unzip -q "$TEMP_DIR/template.zip" -d "$TEMP_DIR"
cp -r "$TEMP_DIR"/*/* "$SITE_DIR/" 2>/dev/null || cp -r "$TEMP_DIR"/* "$SITE_DIR/"
rm -rf "$TEMP_DIR"; chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || chmod -R 755 "$SITE_DIR"
EOF
    chmod +x "$ROTATE_SCRIPT"
    bash "$ROTATE_SCRIPT" >/dev/null 2>&1
    echo "0 4 1,15 * * root $ROTATE_SCRIPT >/dev/null 2>&1" > "$CRON_FILE"

    # 2. Nginx Config
    cat <<EOF > "$INSTALL_DIR/nginx.conf"
server {
    listen 8080; listen [::]:8080;
    server_name 127.0.0.1 localhost ${NODE_DOMAIN};
    root /var/www/html; index index.html;
    access_log off; error_page 404 /index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF

    # 3. Docker Compose
    cat <<EOF > "$INSTALL_DIR/docker-compose.yml"
services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /var/www/html:/var/www/html:ro
    network_mode: host
    logging: { driver: 'json-file', options: { max-size: '10m', max-file: '3' } }

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=${NODE_SECRET}
    volumes:
      - /dev/shm:/dev/shm:rw
      - ${CERT_DIR}/fullchain.pem:/cert/fullchain.pem:ro
      - ${CERT_DIR}/privkey.pem:/cert/privkey.pem:ro
    depends_on:
      - remnawave-nginx
    logging: { driver: 'json-file', options: { max-size: '10m', max-file: '3' } }
EOF

    cd "$INSTALL_DIR" && docker compose up -d --remove-orphans --force-recreate >/dev/null 2>&1
    sleep 5
    
    if docker ps | grep -q "remnanode"; then
        printf "\n%b\n" "${C_GREEN}✅ ВСЁ ГОТОВО!${C_RESET}"
        echo "   Нода: $NODE_NAME подключена к Панели."
        echo "   SSL:  $CERT_DIR"
    else
        printf "\n%b\n" "${C_RED}❌ Ошибка старта контейнера.${C_RESET}"
        docker logs remnanode --tail 20
    fi
}

# ============================================================ #
#                     MAIN EXECUTION                           #
# ============================================================ #

# 1. Проверки
install_base_tools
check_existing_installation

# 2. Сбор данных и API
step_auth
step_create_profile
step_create_node

# 3. Установка на сервер
install_full_tools
step_system_setup
step_certificates
step_deploy