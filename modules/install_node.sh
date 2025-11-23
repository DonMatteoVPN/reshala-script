#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ УСТАНОВКИ REMNAWAVE NODE (API AUTOMATION)     ==
# ==        VLESS-WS-TLS + AUTO-PROFILE + AUTO-KEY          ==
# ============================================================ #

# --- Цвета ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Пути и Конфиги ---
INSTALL_DIR="/opt/remnawave-node"
CERT_DIR="/root/certs_node"
SITE_DIR="/var/www/html"
ROTATE_SCRIPT="/usr/local/bin/reshala-rotate-site"
SMART_RENEW_SCRIPT="/usr/local/bin/reshala-smart-renew"
CRON_FILE="/etc/cron.d/remnawave-node"

# --- Переменные ---
NODE_DOMAIN=""
NODE_NAME=""
NODE_SECRET=""  # Будет получен через API
API_URL=""
API_USER=""
API_PASS=""
API_TOKEN=""
PROFILE_ID=""
NODE_ID=""

CERT_STRATEGY="" 
CF_TOKEN=""
CF_EMAIL=""
PANEL_IP=""     # Для SSH копирования сертификатов (если нужно)
PANEL_PORT="22"
PANEL_USER="root"
PANEL_PASS=""

run_cmd() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
safe_read() { read -e -p "$1" -i "$2" result; echo "${result:-$2}"; }

# ============================================================ #
#                     API ФУНКЦИИ (МОЗГИ)                      #
# ============================================================ #

api_login() {
    echo ""
    printf "%b" "🔐 Авторизация в Панели... "
    
    # Чистим URL от слешей на конце
    API_URL=${API_URL%/}
    
    local RESPONSE
    RESPONSE=$(curl -s -X POST "${API_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$API_USER\", \"password\": \"$API_PASS\"}")

    # Парсим токен
    API_TOKEN=$(echo "$RESPONSE" | jq -r '.accessToken')

    if [[ "$API_TOKEN" == "null" || -z "$API_TOKEN" ]]; then
        printf "%b\n" "${C_RED}ОШИБКА!${C_RESET}"
        echo "Ответ сервера: $RESPONSE"
        echo "Проверь логин, пароль и URL."
        exit 1
    else
        printf "%b\n" "${C_GREEN}Успешно.${C_RESET}"
    fi
}

api_create_profile() {
    printf "%b" "📝 Создаю профиль VLESS-WS-TLS... "
    
    # Формируем JSON для профиля
    local PROFILE_JSON=$(cat <<EOF
{
  "name": "${NODE_NAME}_Profile",
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

    local RESPONSE
    RESPONSE=$(curl -s -X POST "${API_URL}/api/configurations" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PROFILE_JSON")

    PROFILE_ID=$(echo "$RESPONSE" | jq -r '.id')

    if [[ "$PROFILE_ID" == "null" || -z "$PROFILE_ID" ]]; then
        # Если ошибка, возможно такой профиль уже есть? Пофиг, создаем новый с рандомом
        printf "%b\n" "${C_YELLOW}Дубль имени?${C_RESET}"
        # В рамках упрощения - просто падаем с ошибкой, чтобы юзер видел
        echo "Ошибка создания профиля: $RESPONSE"
        exit 1
    else
        printf "%b\n" "${C_GREEN}OK (ID: $PROFILE_ID)${C_RESET}"
    fi
}

api_create_node() {
    printf "%b" "KV Создаю ноду ${NODE_NAME}... "
    
    # 1. Создаем ноду
    local NODE_JSON=$(cat <<EOF
{
  "name": "${NODE_NAME}",
  "address": "${NODE_DOMAIN}",
  "configurationId": "${PROFILE_ID}"
}
EOF
)
    # Внимание: эндпоинт может отличаться в разных версиях, обычно /api/nodes или /api/hosts
    # В Remnawave структура: Host -> Node. Но в API часто просто /api/nodes
    # Пробуем создать ноду и сразу привязать конфиг
    
    local RESPONSE
    RESPONSE=$(curl -s -X POST "${API_URL}/api/nodes" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$NODE_JSON")
        
    NODE_ID=$(echo "$RESPONSE" | jq -r '.id')
    # В ответе на создание ноды обычно прилетает secretKey
    NODE_SECRET=$(echo "$RESPONSE" | jq -r '.secretKey')

    if [[ "$NODE_ID" == "null" ]]; then
        printf "%b\n" "${C_RED}ОШИБКА!${C_RESET}"
        echo "$RESPONSE"
        exit 1
    fi
    
    printf "%b\n" "${C_GREEN}OK!${C_RESET}"
    echo "   🔑 Получен SECRET_KEY: ${NODE_SECRET:0:15}..."
}

# ============================================================ #
#                     ПРОВЕРКА СТАТУСА                         #
# ============================================================ #
check_existing_installation() {
    if [ -d "$INSTALL_DIR" ] || docker ps | grep -q "remnanode"; then
        clear
        printf "%b\n" "${C_RED}╔══════════════════════════════════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_RED}║       ⚠️  ВНИМАНИЕ! НОДА УЖЕ УСТАНОВЛЕНА! ⚠️             ║${C_RESET}"
        printf "%b\n" "${C_RED}╚══════════════════════════════════════════════════════════╝${C_RESET}"
        echo "   [1] 🔄 СНЕСТИ И ПЕРЕУСТАНОВИТЬ (Полный сброс)"
        echo "   [b] 🔙 Отмена"
        local choice=$(safe_read "Выбор: " "b")
        case "$choice" in
            1) 
                echo "🧨 Сношу..."
                if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then cd "$INSTALL_DIR" && docker compose down -v 2>/dev/null; fi
                rm -rf "$INSTALL_DIR" "$CRON_FILE" "$ROTATE_SCRIPT" "$SMART_RENEW_SCRIPT"
                ;;
            *) exit 0 ;;
        esac
    fi
}

# ============================================================ #
#                     СБОР ДАННЫХ                              #
# ============================================================ #
collect_data() {
    clear
    printf "%b\n" "${C_CYAN}🚀 АВТО-УСТАНОВКА НОДЫ (API MODE)${C_RESET}"
    
    # --- ДАННЫЕ ПАНЕЛИ (ДЛЯ API) ---
    echo ""
    printf "%b\n" "${C_BOLD}[ 1. ПОДКЛЮЧЕНИЕ К ПАНЕЛИ ]${C_RESET}"
    API_URL=$(safe_read "🔗 URL Панели (http://ip:3000 или https://panel.domain): " "")
    API_USER=$(safe_read "👤 Логин Админа: " "admin")
    read -s -p "🔑 Пароль Админа: " API_PASS
    echo ""
    
    # Тест логина сразу
    install_pkgs_minimal # Нужен jq и curl
    api_login

    # --- ДАННЫЕ НОДЫ ---
    echo ""
    printf "%b\n" "${C_BOLD}[ 2. ПАРАМЕТРЫ НОВОЙ НОДЫ ]${C_RESET}"
    NODE_NAME=$(safe_read "🏷️  Имя ноды (English, например Turkey_1): " "Node_1")
    NODE_DOMAIN=$(safe_read "🌐 Домен ноды (tr1.site.com): " "")
    [[ -z "$NODE_DOMAIN" ]] && { echo "❌ Домен нужен."; exit 1; }

    # --- ДАННЫЕ СЕРТИФИКАТОВ ---
    echo ""
    printf "%b\n" "${C_BOLD}[ 3. СЕРТИФИКАТЫ (SSL) ]${C_RESET}"
    echo "   [1] ☁️  Cloudflare API (Wildcard)"
    echo "   [2] 📥 Скопировать с Панели (SSH/Local)"
    echo "   [3] 🆕 Certbot Standalone (Авто-выпуск)"
    echo "   [4] 📂 Локальные файлы"
    CERT_STRATEGY=$(safe_read "Выбор (1-4): " "1")
    
    case "$CERT_STRATEGY" in
        1) 
            printf "%b\n" "${C_YELLOW}--- Cloudflare ---${C_RESET}"
            CF_TOKEN=$(safe_read "Token: " "")
            CF_EMAIL=$(safe_read "Email: " "")
            ;;
        2)
            # Берем IP из URL панели для SSH, но даем исправить
            local default_ip=$(echo "$API_URL" | sed -e 's|^[^/]*//||' -e 's|:.*$||')
            printf "%b\n" "${C_YELLOW}--- SSH Данные ---${C_RESET}"
            PANEL_IP=$(safe_read "IP Сервера Панели: " "$default_ip")
            PANEL_PORT=$(safe_read "SSH Порт: " "22")
            PANEL_USER=$(safe_read "SSH User: " "root")
            read -s -p "SSH Пароль: " PANEL_PASS; echo ""
            
            # Проверка локальности
            [[ "$PANEL_IP" == "127.0.0.1" || "$PANEL_IP" == "localhost" || "$PANEL_IP" == "$(hostname -I | awk '{print $1}')" ]] && IS_LOCAL_PANEL=1
            ;;
    esac
}

install_pkgs_minimal() {
    if ! command -v jq &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null
        apt-get install -y -qq curl jq >/dev/null
    fi
}

install_pkgs_full() {
    echo ""
    printf "%b" "🔧 Ставлю полный пакет... "
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq wget unzip socat git cron sshpass ufw certbot >/dev/null
    if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sh >/dev/null; fi
    printf "%b\n" "${C_GREEN}OK${C_RESET}"
}

# ============================================================ #
#                     НАСТРОЙКА СИСТЕМЫ                        #
# ============================================================ #
setup_system() {
    echo "🛡️ Firewall..."
    if ! command -v ufw &>/dev/null; then apt-get install -y ufw >/dev/null; fi
    local ssh_p=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1); ssh_p=${ssh_p:-22}
    ufw allow "$ssh_p"/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw allow 2222/tcp >/dev/null 2>&1
    ufw delete allow 80/tcp >/dev/null 2>&1
    if ! ufw status | grep -q "Status: active"; then echo "y" | ufw enable >/dev/null; else ufw reload >/dev/null; fi
}

# ============================================================ #
#                     СЕРТИФИКАТЫ                              #
# ============================================================ #
setup_certificates() {
    mkdir -p "$CERT_DIR"
    local RELOAD_CMD="docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode"

    case $CERT_STRATEGY in
        1) # Cloudflare
            if [ ! -d "/root/.acme.sh" ]; then curl https://get.acme.sh | sh -s email="$CF_EMAIL" >/dev/null 2>&1; fi
            export CF_Token="$CF_TOKEN"; export CF_Email="$CF_EMAIL"
            /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$NODE_DOMAIN" -d "*.$NODE_DOMAIN" --force
            /root/.acme.sh/acme.sh --install-cert -d "$NODE_DOMAIN" --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "$RELOAD_CMD"
            ;;
        2) # Panel Copy (Smart)
            echo "📥 Настройка копирования..."
            cat <<EOF > "$SMART_RENEW_SCRIPT"
#!/bin/bash
CERT="$CERT_DIR/fullchain.pem"
if [ -f "\$CERT" ] && openssl x509 -checkend \$((7*86400)) -noout -in "\$CERT"; then exit 0; fi
EOF
            if [ $IS_LOCAL_PANEL -eq 1 ]; then
                # Local logic (упрощено)
                echo "cp -L /etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem $CERT_DIR/fullchain.pem" >> "$SMART_RENEW_SCRIPT"
                echo "cp -L /etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem $CERT_DIR/privkey.pem" >> "$SMART_RENEW_SCRIPT"
            else
                # SSH logic (упрощено, предполагаем дефолт путь)
                echo "sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem $CERT_DIR/fullchain.pem" >> "$SMART_RENEW_SCRIPT"
                echo "sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem $CERT_DIR/privkey.pem" >> "$SMART_RENEW_SCRIPT"
            fi
            cat <<EOF >> "$SMART_RENEW_SCRIPT"
chmod 644 $CERT_DIR/*
$RELOAD_CMD
EOF
            chmod +x "$SMART_RENEW_SCRIPT"
            bash "$SMART_RENEW_SCRIPT" # Первый прогон
            echo "0 3 * * * root $SMART_RENEW_SCRIPT >> /var/log/cert-renew.log 2>&1" > "$CRON_FILE"
            ;;
        3) # Certbot Standalone
            echo "🆕 Выпуск Certbot..."
            ufw allow 80/tcp >/dev/null
            certbot certonly --standalone -d "$NODE_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
            cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
            cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
            ufw delete allow 80/tcp >/dev/null
            
            cat <<EOF > "$SMART_RENEW_SCRIPT"
#!/bin/bash
certbot renew --non-interactive --pre-hook "ufw allow 80/tcp; docker stop remnawave-nginx" --post-hook "ufw delete allow 80/tcp; docker start remnawave-nginx; cp -L /etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem $CERT_DIR/fullchain.pem; cp -L /etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem $CERT_DIR/privkey.pem; $RELOAD_CMD"
EOF
            chmod +x "$SMART_RENEW_SCRIPT"
            echo "0 3,15 * * * root $SMART_RENEW_SCRIPT >> /var/log/cert-renew.log 2>&1" > "$CRON_FILE"
            ;;
    esac
    chmod 644 "$CERT_DIR/"*
}

setup_fake_site() {
    echo "🎭 Сайт-заглушка..."
    cat << 'EOF' > "$ROTATE_SCRIPT"
#!/bin/bash
SITE_DIR="/var/www/html"; TEMP_DIR="/tmp/website_template"
URLS=("https://www.free-css.com/assets/files/free-css-templates/download/page296/healet.zip" "https://www.free-css.com/assets/files/free-css-templates/download/page296/carvilla.zip" "https://www.free-css.com/assets/files/free-css-templates/download/page296/oxer.zip")
RANDOM_URL=${URLS[$RANDOM % ${#URLS[@]}]}
rm -rf "$TEMP_DIR" "$SITE_DIR"/*; mkdir -p "$TEMP_DIR" "$SITE_DIR"
wget -q -O "$TEMP_DIR/template.zip" "$RANDOM_URL"; unzip -q "$TEMP_DIR/template.zip" -d "$TEMP_DIR"
CONTENT_DIR=$(find "$TEMP_DIR" -name "index.html" | head -n 1 | xargs dirname)
if [ -n "$CONTENT_DIR" ]; then cp -r "$CONTENT_DIR"/* "$SITE_DIR/"; fi
rm -rf "$TEMP_DIR"; chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || chmod -R 755 "$SITE_DIR"
EOF
    chmod +x "$ROTATE_SCRIPT"
    bash "$ROTATE_SCRIPT" >/dev/null 2>&1
    echo "0 4 1,15 * * root $ROTATE_SCRIPT >> /var/log/site-rotate.log 2>&1" >> "$CRON_FILE"
}

deploy_docker() {
    mkdir -p "$INSTALL_DIR"
    # Используем полученный через API SECRET_KEY
    cat <<EOF > "$INSTALL_DIR/docker-compose.yml"
services:
  remnawave-nginx:
    image: nginx:1.28
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /var/www/html:/var/www/html:ro
    network_mode: host
    logging: { driver: 'json-file', options: { max-size: '30m', max-file: '5' } }

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
    logging: { driver: 'json-file', options: { max-size: '30m', max-file: '5' } }
EOF

    cat <<EOF > "$INSTALL_DIR/nginx.conf"
server {
    listen 8080; listen [::]:8080;
    server_name 127.0.0.1 localhost ${NODE_DOMAIN};
    root /var/www/html; index index.html;
    access_log off; error_page 404 /index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF

    cd "$INSTALL_DIR" && docker compose up -d --remove-orphans --force-recreate >/dev/null 2>&1
    sleep 5
    if docker ps | grep -q "remnanode"; then
        printf "\n%b\n" "${C_GREEN}✅ ГОТОВО! Нода добавлена в панель и запущена.${C_RESET}"
        echo "   Профиль создан: ${NODE_NAME}_Profile"
        echo "   Нода создана:   ${NODE_NAME}"
        echo "   SSL:            ОК"
        echo "   Проверь в панели (Nodes), должен быть зеленый статус."
    else
        printf "%b\n" "${C_RED}❌ Ошибка запуска контейнеров.${C_RESET}"
    fi
}

# MAIN FLOW
check_existing_installation
collect_data
api_create_profile
api_create_node
install_pkgs_full
setup_system
setup_certificates
setup_fake_site
deploy_docker