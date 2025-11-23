#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ УСТАНОВКИ REMNAWAVE NODE (VLESS-WS-TLS)       ==
# ==          BASED ON BEST PRACTICES & RESHALA STYLE       ==
# ============================================================ #

# --- Цвета ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Конфигурация ---
INSTALL_DIR="/opt/remnawave-node"
CERT_DIR="/root/certs_node"
SITE_DIR="/var/www/html"
ROTATE_SCRIPT="/usr/local/bin/reshala-rotate-site"
CRON_FILE="/etc/cron.d/remnawave-node"

# --- Глобальные переменные ---
NODE_DOMAIN=""
NODE_SECRET=""
CERT_STRATEGY="" 
CF_TOKEN=""
CF_EMAIL=""
PANEL_IP=""
PANEL_PORT="22"
PANEL_USER="root"
PANEL_PASS=""
IS_LOCAL_PANEL=0

run_cmd() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
safe_read() { read -e -p "$1" -i "$2" result; echo "${result:-$2}"; }

# ============================================================ #
#                     ПРОВЕРКА СТАТУСА                         #
# ============================================================ #
check_existing_installation() {
    if [ -d "$INSTALL_DIR" ] || docker ps | grep -q "remnanode"; then
        clear
        printf "%b\n" "${C_RED}╔══════════════════════════════════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_RED}║       ⚠️  ВНИМАНИЕ! НОДА УЖЕ УСТАНОВЛЕНА! ⚠️             ║${C_RESET}"
        printf "%b\n" "${C_RED}╚══════════════════════════════════════════════════════════╝${C_RESET}"
        echo ""
        echo "   [1] 🔄 СНЕСТИ И ПЕРЕУСТАНОВИТЬ (Полный сброс)"
        echo "   [2] 🛠  Только обновить конфиги (Docker Compose)"
        echo "   [b] 🔙 Отмена"
        
        local choice=$(safe_read "Твой выбор: " "b")
        case "$choice" in
            1) 
                echo "🧨 Уничтожаю старую ноду..."
                if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
                    cd "$INSTALL_DIR" && docker compose down -v 2>/dev/null
                fi
                rm -rf "$INSTALL_DIR"
                rm -f "$CRON_FILE"
                echo "✅ Площадка зачищена."
                ;;
            2)
                echo "🔧 Режим обновления..."
                # Пропускаем сбор данных, используем существующие (если найдем) или запрашиваем минимум
                # Для простоты в этом режиме мы просто перезапишем docker-compose, но данные спросим заново
                ;;
            *) exit 0 ;;
        esac
    fi
}

# ============================================================ #
#                     СБОР ИНФОРМАЦИИ                          #
# ============================================================ #
collect_data() {
    clear
    printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    printf "%b\n" "${C_CYAN}║        🚀 УСТАНОВКА REMNAWAVE NODE (VLESS-WS-TLS)            ║${C_RESET}"
    printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    
    # 1. Данные Ноды
    printf "%b\n" "${C_BOLD}[ 1. НАСТРОЙКИ НОДЫ ]${C_RESET}"
    NODE_DOMAIN=$(safe_read "🌐 Домен ноды (напр. tr1.site.com): " "")
    [[ -z "$NODE_DOMAIN" ]] && { echo "❌ Домен нужен."; exit 1; }
    
    NODE_SECRET=$(safe_read "🔑 SECRET_KEY ноды (из Панели): " "")
    [[ -z "$NODE_SECRET" ]] && { echo "❌ Ключ нужен."; exit 1; }
    
    # 2. Выбор стратегии сертификатов
    echo ""
    printf "%b\n" "${C_BOLD}[ 2. СЕРТИФИКАТЫ (SSL) ]${C_RESET}"
    echo "   [1] ☁️  Cloudflare API (Лучший выбор для Wildcard)"
    echo "   [2] 📥 Скопировать с Панели (SSH/Local)"
    echo "   [3] 🆕 Выпустить Certbot Standalone (Нужен открытый 80 порт)"
    echo "   [4] 📂 Локальные файлы (уже есть в $CERT_DIR)"
    
    CERT_STRATEGY=$(safe_read "Выбор (1-4): " "1")
    
    case "$CERT_STRATEGY" in
        1) 
            echo ""
            printf "%b\n" "${C_YELLOW}--- Cloudflare Settings ---${C_RESET}"
            CF_TOKEN=$(safe_read "API Token: " "")
            CF_EMAIL=$(safe_read "Email: " "")
            [[ -z "$CF_TOKEN" ]] && { echo "❌ Token нужен."; exit 1; }
            ;;
        2)
            echo ""
            printf "%b\n" "${C_YELLOW}--- Panel Settings ---${C_RESET}"
            PANEL_IP=$(safe_read "IP Панели: " "")
            # Проверка на локалхост
            if [[ "$PANEL_IP" == "127.0.0.1" || "$PANEL_IP" == "localhost" || "$PANEL_IP" == "$(hostname -I | awk '{print $1}')" ]]; then
                IS_LOCAL_PANEL=1
                echo "✅ Панель на этом же сервере."
            else
                IS_LOCAL_PANEL=0
                PANEL_PORT=$(safe_read "SSH Порт: " "22")
                PANEL_USER=$(safe_read "User: " "root")
                echo "🔐 Пароль root от Панели:"
                read -s -p "Пароль: " PANEL_PASS
                echo ""
                
                # Test Connection
                if ! command -v sshpass &>/dev/null; then apt-get update -qq && apt-get install -y -qq sshpass; fi
                echo "📡 Проверка соединения..."
                if ! sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "$PANEL_PORT" "$PANEL_USER@$PANEL_IP" exit 2>/dev/null; then
                    echo "❌ Ошибка соединения с панелью! Проверь IP/Порт/Пароль."; exit 1
                else
                    echo "✅ Связь есть."
                fi
            fi
            ;;
        3)
            echo "ℹ️  Внимание: Для этого порт 80 должен быть свободен."
            ;;
        4) 
            echo "ℹ️  Положи файлы fullchain.pem и privkey.pem в $CERT_DIR перед продолжением."
            sleep 2
            ;;
    esac
}

# ============================================================ #
#                     УСТАНОВКА СОФТА                          #
# ============================================================ #
install_pkgs() {
    echo ""
    printf "%b" "🔧 Ставлю инструменты... "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq curl wget unzip jq socat git cron sshpass ufw >/dev/null
    
    if ! command -v docker &> /dev/null; then
        printf "🐳 Ставлю Docker... "
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    fi
    printf "%b\n" "${C_GREEN}OK${C_RESET}"
}

# ============================================================ #
#                     FIREWALL (КРИТИЧНО)                      #
# ============================================================ #
setup_firewall() {
    echo ""
    printf "%b\n" "${C_CYAN}🛡️ Настройка Firewall (Открываем порты)...${C_RESET}"
    
    # Открываем порты для Xray, Nginx и API Панели
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    
    # ВАЖНО: Порт для связи с панелью!
    ufw allow 2222/tcp >/dev/null 2>&1
    
    # Если UFW включен - перезагружаем правила, если нет - не трогаем (чтобы не залочить доступ)
    if ufw status | grep -q "Status: active"; then
        ufw reload >/dev/null 2>&1
        echo "✅ Порты 80, 443, 2222 открыты в UFW."
    else
        echo "ℹ️  UFW не активен, полагаемся на настройки хостинга."
    fi
}

# ============================================================ #
#                     SSL СЕРТИФИКАТЫ                          #
# ============================================================ #
setup_certificates() {
    mkdir -p "$CERT_DIR"
    echo ""
    printf "%b\n" "${C_CYAN}🔒 Настройка SSL...${C_RESET}"
    
    local RELOAD_CMD="docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode"

    case $CERT_STRATEGY in
        1) # Cloudflare (acme.sh)
            if [ ! -d "/root/.acme.sh" ]; then
                curl https://get.acme.sh | sh -s email="$CF_EMAIL" >/dev/null 2>&1
            fi
            export CF_Token="$CF_TOKEN"; export CF_Email="$CF_EMAIL"
            
            echo "🔑 Выпуск сертификата (acme.sh)..."
            /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$NODE_DOMAIN" -d "*.$NODE_DOMAIN" --force
            /root/.acme.sh/acme.sh --install-cert -d "$NODE_DOMAIN" \
                --key-file "$CERT_DIR/privkey.pem" \
                --fullchain-file "$CERT_DIR/fullchain.pem" \
                --reloadcmd "$RELOAD_CMD"
            ;;
            
        2) # Panel Copy
            echo "📥 Копирование сертификатов..."
            # Улучшенный поиск путей (как в прошлом фиксе)
            local FOUND_PATH=""
            local PATHS=("/root/.acme.sh/${NODE_DOMAIN}_ecc" "/root/.acme.sh/${NODE_DOMAIN}" "/etc/letsencrypt/live/${NODE_DOMAIN}")
            
            if [ $IS_LOCAL_PANEL -eq 1 ]; then
                for p in "${PATHS[@]}"; do [[ -f "$p/fullchain.pem" ]] && FOUND_PATH="$p" && break; done
                if [ -z "$FOUND_PATH" ]; then read -e -p "❌ Путь локально не найден. Введи вручную: " FOUND_PATH; fi
                
                cp -L "$FOUND_PATH/fullchain."* "$CERT_DIR/fullchain.pem"
                cp -L "$FOUND_PATH/"*key* "$CERT_DIR/privkey.pem"
                # Cron Local
                echo "0 3 * * 1 cp -L $FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem && cp -L $FOUND_PATH/*key* $CERT_DIR/privkey.pem && $RELOAD_CMD" > "$CRON_FILE"
            else
                for p in "${PATHS[@]}"; do
                    if sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -p "$PANEL_PORT" "$PANEL_USER@$PANEL_IP" "[ -f $p/fullchain.pem ]"; then FOUND_PATH="$p"; break; fi
                done
                if [ -z "$FOUND_PATH" ]; then read -e -p "❌ Путь удаленно не найден. Введи вручную: " FOUND_PATH; fi
                
                sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.*" "$CERT_DIR/fullchain.pem"
                sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/*key*" "$CERT_DIR/privkey.pem"
                
                # Cron SSH
                echo "0 3 * * 1 sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem && sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/*key* $CERT_DIR/privkey.pem && $RELOAD_CMD" > "$CRON_FILE"
            fi
            ;;
            
        3) # Certbot Standalone
            echo "🆕 Выпускаю сертификат через Certbot..."
            # Останавливаем то, что может занимать 80 порт
            systemctl stop nginx 2>/dev/null
            docker stop remnawave-nginx 2>/dev/null
            
            certbot certonly --standalone -d "$NODE_DOMAIN" --non-interactive --agree-tos -m admin@"$NODE_DOMAIN"
            
            if [ -f "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" ]; then
                cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
                cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
                # Cron Certbot
                echo "0 3 * * 1 certbot renew --quiet && cp -L /etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem $CERT_DIR/fullchain.pem && cp -L /etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem $CERT_DIR/privkey.pem && $RELOAD_CMD" > "$CRON_FILE"
            else
                echo "❌ Certbot не смог получить сертификат. Проверь DNS и 80 порт."
                exit 1
            fi
            ;;
    esac
    
    if [[ ! -s "$CERT_DIR/fullchain.pem" ]]; then echo "❌ Ошибка сертификатов!"; exit 1; fi
    chmod 644 "$CERT_DIR/"*
}

# ============================================================ #
#                     САЙТ-МАСКИРОВКА                          #
# ============================================================ #
setup_fake_site() {
    echo "🎭 Установка сайта-заглушки..."
    cat << 'EOF' > "$ROTATE_SCRIPT"
#!/bin/bash
SITE_DIR="/var/www/html"
TEMP_DIR="/tmp/website_template"
URLS=(
    "https://www.free-css.com/assets/files/free-css-templates/download/page296/healet.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page296/carvilla.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page296/oxer.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page295/antique-cafe.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page293/fitapp.zip"
)
RANDOM_URL=${URLS[$RANDOM % ${#URLS[@]}]}
rm -rf "$TEMP_DIR" "$SITE_DIR"/*
mkdir -p "$TEMP_DIR" "$SITE_DIR"
wget -q -O "$TEMP_DIR/template.zip" "$RANDOM_URL"
unzip -q "$TEMP_DIR/template.zip" -d "$TEMP_DIR"
CONTENT_DIR=$(find "$TEMP_DIR" -name "index.html" | head -n 1 | xargs dirname)
if [ -n "$CONTENT_DIR" ]; then cp -r "$CONTENT_DIR"/* "$SITE_DIR/"; fi
rm -rf "$TEMP_DIR"
chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || chmod -R 755 "$SITE_DIR"
EOF
    chmod +x "$ROTATE_SCRIPT"
    bash "$ROTATE_SCRIPT" >/dev/null 2>&1
    
    # Добавляем ротацию в cron
    echo "0 4 1,15 * * root $ROTATE_SCRIPT >> /var/log/site-rotate.log 2>&1" >> "$CRON_FILE"
}

# ============================================================ #
#                     ЗАПУСК КОНТЕЙНЕРОВ                       #
# ============================================================ #
deploy_docker() {
    mkdir -p "$INSTALL_DIR"
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
    logging:
      driver: 'json-file'
      options: { max-size: '30m', max-file: '5' }

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
    logging:
      driver: 'json-file'
      options: { max-size: '30m', max-file: '5' }
EOF

    cat <<EOF > "$INSTALL_DIR/nginx.conf"
server {
    listen 8080;
    listen [::]:8080;
    server_name 127.0.0.1 localhost ${NODE_DOMAIN};
    root /var/www/html;
    index index.html;
    access_log off;
    error_page 404 /index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF

    echo ""
    echo "🔥 Запуск..."
    cd "$INSTALL_DIR" && docker compose up -d --remove-orphans --force-recreate >/dev/null 2>&1
    
    sleep 5
    if docker ps | grep -q "remnanode"; then
        printf "%b\n" "${C_GREEN}✅ НОДА УСПЕШНО УСТАНОВЛЕНА!${C_RESET}"
        echo "------------------------------------------------"
        echo "   Домен: $NODE_DOMAIN"
        echo "   SSL:   $CERT_DIR (Авто-обновление вкл)"
        echo "   API:   Порт 2222 (Открыт в UFW)"
        echo "   Web:   Порт 8080 (Авто-ротация сайта)"
        echo "------------------------------------------------"
        echo "📝 СТАТУС:"
        echo "   1. Сертификаты лежат в $CERT_DIR"
        echo "   2. Cron задача создана: $CRON_FILE"
        echo "   3. Панель должна видеть ноду (порт 2222 открыт)"
    else
        printf "%b\n" "${C_RED}❌ Ошибка запуска Docker.${C_RESET}"
    fi
}

# MAIN FLOW
check_existing_installation
collect_data
install_pkgs
setup_firewall
setup_certificates
setup_fake_site
deploy_docker