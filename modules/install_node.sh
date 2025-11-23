#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ УСТАНОВКИ REMNAWAVE NODE (API AUTOMATION)     ==
# ==      FULL CYCLE: AUTH -> PROFILE -> NODE -> DEPLOY     ==
# ============================================================ #

# --- Цвета ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Пути ---
INSTALL_DIR="/opt/remnawave-node"
CERT_DIR="/root/certs_node"
SITE_DIR="/var/www/html"
ROTATE_SCRIPT="/usr/local/bin/reshala-rotate-site"
SMART_RENEW_SCRIPT="/usr/local/bin/reshala-smart-renew"
CRON_FILE="/etc/cron.d/remnawave-node"

# --- Переменные ---
API_URL=""
API_TOKEN=""
NODE_NAME=""
NODE_DOMAIN=""
NODE_SECRET=""
PROFILE_ID=""
CERT_STRATEGY=""
CF_TOKEN=""
CF_EMAIL=""
# Переменные для SSH копирования
PANEL_IP=""
PANEL_PORT="22"
PANEL_USER="root"
PANEL_PASS=""
IS_LOCAL_PANEL=0

# Утилита для запуска от root
run_cmd() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
safe_read() { read -e -p "$1" -i "$2" result; echo "${result:-$2}"; }

# ============================================================ #
#                0. ПРОВЕРКА И ПОДГОТОВКА                      #
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
                echo "🧨 Сношу старую ноду..."
                if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then cd "$INSTALL_DIR" && docker compose down -v 2>/dev/null; fi
                rm -rf "$INSTALL_DIR" "$CRON_FILE" "$ROTATE_SCRIPT" "$SMART_RENEW_SCRIPT"
                ;;
            *) exit 0 ;;
        esac
    fi
}

install_minimal_tools() {
    # Нам нужны curl и jq для работы с API прямо сейчас
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        echo "🔧 Ставлю curl и jq для работы API..."
        apt-get update -qq >/dev/null
        apt-get install -y -qq curl jq >/dev/null
    fi
}

# ============================================================ #
#                1. РАБОТА С API ПАНЕЛИ                        #
# ============================================================ #
api_auth_flow() {
    clear
    printf "%b\n" "${C_CYAN}🚀 АВТО-НАСТРОЙКА ЧЕРЕЗ API ПАНЕЛИ${C_RESET}"
    echo ""
    printf "%b\n" "${C_BOLD}[ 1. ПОДКЛЮЧЕНИЕ К ПАНЕЛИ ]${C_RESET}"
    
    API_URL=$(safe_read "🔗 URL Панели (напр. https://panel.domain.com): " "")
    # Убираем слеш в конце
    API_URL=${API_URL%/}
    
    echo "Как авторизуемся?"
    echo "   [1] Логин и Пароль (Admin)"
    echo "   [2] Вставить Token вручную"
    local auth_method=$(safe_read "Выбор: " "1")
    
    if [[ "$auth_method" == "2" ]]; then
        echo "Вставь Bearer token:"
        read -r API_TOKEN
    else
        local A_USER=$(safe_read "👤 Логин: " "admin")
        echo "🔑 Пароль:"
        read -s A_PASS
        
        printf "\n🔄 Логинюсь... "
        # Используем -L для редиректов и -c cookie-jar на всякий случай
        local RESPONSE
        RESPONSE=$(curl -s -L -X POST "${API_URL}/api/auth/login" \
            -H "Content-Type: application/json" \
            -d "{\"username\": \"$A_USER\", \"password\": \"$A_PASS\"}")
            
        # Проверка на HTML (ошибка Nginx/Cloudflare)
        if [[ "$RESPONSE" == *"<html"* ]]; then
            printf "%b\n" "${C_RED}ОШИБКА!${C_RESET}"
            echo "Сервер вернул HTML. Проверь URL (возможно нужно https или порт)."
            exit 1
        fi
        
        API_TOKEN=$(echo "$RESPONSE" | jq -r '.accessToken')
        
        if [[ "$API_TOKEN" == "null" || -z "$API_TOKEN" ]]; then
            printf "%b\n" "${C_RED}НЕВЕРНО!${C_RESET}"
            echo "Ответ: $RESPONSE"
            exit 1
        else
            printf "%b\n" "${C_GREEN}УСПЕХ!${C_RESET}"
        fi
    fi
}

api_setup_node() {
    echo ""
    printf "%b\n" "${C_BOLD}[ 2. ПАРАМЕТРЫ НОВОЙ НОДЫ ]${C_RESET}"
    NODE_NAME=$(safe_read "🏷️  Имя Ноды (English): " "Node_$(hostname)")
    NODE_DOMAIN=$(safe_read "🌐 Домен Ноды (tr1.site.com): " "")
    [[ -z "$NODE_DOMAIN" ]] && { echo "❌ Домен обязателен!"; exit 1; }

    # --- 2.1 СОЗДАНИЕ ПРОФИЛЯ (CONFIGURATION) ---
    printf "📝 Создаю профиль VLESS-WS-TLS... "
    
    local PROFILE_JSON=$(cat <<EOF
{
  "name": "${NODE_NAME}_Profile_$(date +%s)",
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
    local P_RESP
    P_RESP=$(curl -s -L -X POST "${API_URL}/api/configurations" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PROFILE_JSON")
        
    PROFILE_ID=$(echo "$P_RESP" | jq -r '.id')
    
    if [[ "$PROFILE_ID" == "null" ]]; then
        printf "%b\n" "${C_RED}ОШИБКА СОЗДАНИЯ ПРОФИЛЯ!${C_RESET}"
        echo "Ответ: $P_RESP"
        exit 1
    fi
    printf "%b\n" "${C_GREEN}OK (ID: $PROFILE_ID)${C_RESET}"

    # --- 2.2 СОЗДАНИЕ НОДЫ (HOST) ---
    printf "KV Создаю Ноду и беру ключ... "
    
    # API v2 Remnawave использует /api/hosts (в UI это Nodes)
    # Поля: name, address, configurationId
    local NODE_JSON=$(cat <<EOF
{
  "name": "${NODE_NAME}",
  "address": "${NODE_DOMAIN}",
  "configurationId": "${PROFILE_ID}"
}
EOF
)
    local N_RESP
    N_RESP=$(curl -s -L -X POST "${API_URL}/api/hosts" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$NODE_JSON")
        
    NODE_SECRET=$(echo "$N_RESP" | jq -r '.secretKey')
    
    # Fallback на /api/nodes если hosts не сработал (старые версии)
    if [[ "$NODE_SECRET" == "null" ]]; then
        N_RESP=$(curl -s -L -X POST "${API_URL}/api/nodes" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$NODE_JSON")
        NODE_SECRET=$(echo "$N_RESP" | jq -r '.secretKey')
    fi

    if [[ "$NODE_SECRET" == "null" || -z "$NODE_SECRET" ]]; then
        printf "%b\n" "${C_RED}НЕ УДАЛОСЬ ПОЛУЧИТЬ КЛЮЧ!${C_RESET}"
        echo "Ответ API: $N_RESP"
        exit 1
    fi
    
    printf "%b\n" "${C_GREEN}УСПЕХ!${C_RESET}"
    echo "   🔑 Secret Key получен."
}

# ============================================================ #
#                2. ВЫБОР СЕРТИФИКАТОВ                         #
# ============================================================ #
collect_cert_data() {
    echo ""
    printf "%b\n" "${C_BOLD}[ 3. ИСТОЧНИК СЕРТИФИКАТОВ ]${C_RESET}"
    echo "   [1] ☁️  Cloudflare API (Wildcard)"
    echo "   [2] 📥 Скопировать с Панели (SSH/Local)"
    echo "   [3] 🆕 Certbot Standalone (Авто-выпуск)"
    CERT_STRATEGY=$(safe_read "Выбор (1-3): " "1")
    
    case "$CERT_STRATEGY" in
        1) 
            printf "%b\n" "${C_YELLOW}--- Cloudflare ---${C_RESET}"
            CF_TOKEN=$(safe_read "Token: " "")
            CF_EMAIL=$(safe_read "Email: " "")
            ;;
        2)
            printf "%b\n" "${C_YELLOW}--- SSH Данные Панели ---${C_RESET}"
            local guess_ip=$(echo "$API_URL" | awk -F/ '{print $3}' | cut -d: -f1)
            PANEL_IP=$(safe_read "IP Сервера: " "$guess_ip")
            
            # Проверка на локальность
            local my_ips=$(hostname -I)
            if [[ "$PANEL_IP" == "127.0.0.1" || "$PANEL_IP" == "localhost" || "$my_ips" == *"$PANEL_IP"* ]]; then
                IS_LOCAL_PANEL=1
                echo "✅ Локальная установка (копирую cp)."
            else
                IS_LOCAL_PANEL=0
                PANEL_PORT=$(safe_read "SSH Порт: " "22")
                PANEL_USER=$(safe_read "SSH User: " "root")
                read -s -p "SSH Пароль: " PANEL_PASS; echo ""
                
                # Тест SSH
                if ! command -v sshpass &>/dev/null; then apt-get update -qq && apt-get install -y -qq sshpass; fi
                echo "📡 Тест SSH..."
                if ! sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "$PANEL_PORT" "$PANEL_USER@$PANEL_IP" exit 2>/dev/null; then
                    echo "❌ Ошибка SSH подключения!"; exit 1
                else
                    echo "✅ SSH ОК."
                fi
            fi
            ;;
    esac
}

# ============================================================ #
#                3. УСТАНОВКА СИСТЕМЫ                          #
# ============================================================ #
install_system() {
    echo ""
    printf "%b" "🔧 Ставлю системный софт... "
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq wget unzip socat git cron sshpass ufw certbot >/dev/null
    if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sh >/dev/null; fi
    printf "%b\n" "${C_GREEN}OK${C_RESET}"
    
    # Firewall
    echo "🛡️ Настройка Firewall..."
    if ! command -v ufw &>/dev/null; then apt-get install -y ufw >/dev/null; fi
    local ssh_p=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1); ssh_p=${ssh_p:-22}
    
    ufw allow "$ssh_p"/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw allow 2222/tcp >/dev/null 2>&1
    ufw delete allow 80/tcp >/dev/null 2>&1
    
    if ! ufw status | grep -q "Status: active"; then echo "y" | ufw enable >/dev/null; else ufw reload >/dev/null; fi
}

# ============================================================ #
#                4. НАСТРОЙКА SSL (SMART)                      #
# ============================================================ #
setup_ssl() {
    mkdir -p "$CERT_DIR"
    local RELOAD_CMD="docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode"

    case $CERT_STRATEGY in
        1) # Cloudflare
            if [ ! -d "/root/.acme.sh" ]; then curl https://get.acme.sh | sh -s email="$CF_EMAIL" >/dev/null 2>&1; fi
            export CF_Token="$CF_TOKEN"; export CF_Email="$CF_EMAIL"
            /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$NODE_DOMAIN" -d "*.$NODE_DOMAIN" --force
            /root/.acme.sh/acme.sh --install-cert -d "$NODE_DOMAIN" --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "$RELOAD_CMD"
            ;;
            
        2) # Panel Copy (Smart Scan)
            echo "📥 Сканирую сертификаты на панели..."
            local FOUND_PATH=""
            
            if [ $IS_LOCAL_PANEL -eq 1 ]; then
                # Local scan
                local RAW_LIST=$(ls -d /etc/letsencrypt/live/* /root/.acme.sh/*_ecc /root/.acme.sh/* 2>/dev/null)
                for p in $RAW_LIST; do [[ "$p" == *"$NODE_DOMAIN"* ]] && FOUND_PATH="$p"; done
                if [ -z "$FOUND_PATH" ]; then echo "❌ Сертификат не найден локально."; exit 1; fi
                
                # Create renew script
                cat <<EOF > "$SMART_RENEW_SCRIPT"
#!/bin/bash
cp -L $FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem
cp -L $FOUND_PATH/*key* $CERT_DIR/privkey.pem
chmod 644 $CERT_DIR/*
$RELOAD_CMD
EOF
            else
                # SSH scan
                local RAW_LIST=$(sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -p "$PANEL_PORT" "$PANEL_USER@$PANEL_IP" "ls -d /etc/letsencrypt/live/* /root/.acme.sh/*_ecc /root/.acme.sh/* 2>/dev/null")
                for p in $RAW_LIST; do [[ "$p" == *"$NODE_DOMAIN"* ]] && FOUND_PATH="$p"; done
                
                if [ -z "$FOUND_PATH" ]; then
                    echo "⚠️ Авто-поиск не нашел точного совпадения. Список:"
                    echo "$RAW_LIST"
                    read -e -p "Введи путь к папке сертификата: " FOUND_PATH
                fi
                
                # Create renew script
                cat <<EOF > "$SMART_RENEW_SCRIPT"
#!/bin/bash
sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem
sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/*key* $CERT_DIR/privkey.pem
chmod 644 $CERT_DIR/*
$RELOAD_CMD
EOF
            fi
            
            chmod +x "$SMART_RENEW_SCRIPT"
            bash "$SMART_RENEW_SCRIPT"
            echo "0 3 * * * root $SMART_RENEW_SCRIPT >> /var/log/cert-renew.log 2>&1" > "$CRON_FILE"
            ;;
            
        3) # Certbot Standalone
            echo "🆕 Certbot выпускает..."
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
    if [[ ! -s "$CERT_DIR/fullchain.pem" ]]; then echo "❌ Файлы сертификатов пусты!"; exit 1; fi
}

# ============================================================ #
#                5. САЙТ И DOCKER DEPLOY                       #
# ============================================================ #
deploy_final() {
    echo "🎭 Сайт-заглушка..."
    cat << 'EOF' > "$ROTATE_SCRIPT"
#!/bin/bash
SITE_DIR="/var/www/html"; TEMP_DIR="/tmp/website_template"
URLS=("https://www.free-css.com/assets/files/free-css-templates/download/page296/healet.zip" "https://www.free-css.com/assets/files/free-css-templates/download/page296/carvilla.zip")
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

    mkdir -p "$INSTALL_DIR"
    
    # Генерируем docker-compose с АВТОМАТИЧЕСКИМ SECRET_KEY
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

    echo "🔥 Запускаю..."
    cd "$INSTALL_DIR" && docker compose up -d --remove-orphans --force-recreate >/dev/null 2>&1
    
    sleep 5
    if docker ps | grep -q "remnanode"; then
        printf "\n%b\n" "${C_GREEN}✅ НОДА УСТАНОВЛЕНА И АКТИВИРОВАНА!${C_RESET}"
        echo "   Панель: $API_URL"
        echo "   Нода:   $NODE_NAME ($NODE_DOMAIN)"
        echo "   Профиль: VLESS-WS-TLS"
        echo "   Статус: В панели должна гореть зелёным."
    else
        printf "%b\n" "${C_RED}❌ Ошибка старта Docker.${C_RESET}"
    fi
}

# MAIN SEQUENCE
check_existing_installation
install_minimal_tools
api_auth_flow
collect_cert_data
api_create_profile
api_create_node
install_pkgs_full
setup_system
setup_ssl
setup_fake_site
deploy_final