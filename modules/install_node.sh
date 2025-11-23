#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ УСТАНОВКИ БОЕВОЙ НОДЫ (VLESS-WS-TLS-MIMIC)    ==
# ==             SPECIAL FOR REMNAWAVE PANEL                ==
# ============================================================ #

# --- Цвета ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_GRAY='\033[0;90m'

# --- Пути ---
INSTALL_DIR="/opt/remnawave-node"
CERT_DIR="/root/certs_node"
SITE_DIR="/var/www/html"
ROTATE_SCRIPT="/usr/local/bin/reshala-rotate-site"

# --- Глобальные переменные ---
NODE_DOMAIN=""
NODE_SECRET=""
CERT_STRATEGY="" 
PANEL_IP=""
PANEL_PORT="22"
PANEL_USER="root"
PANEL_PASS=""
IS_LOCAL_PANEL=0
CF_TOKEN=""
CF_EMAIL=""

# --- Утилиты ---
run_cmd() { 
    if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

safe_read() {
    local prompt="$1"
    local default="$2"
    local result
    if [ -n "$default" ]; then
        read -e -p "$prompt" -i "$default" result
    else
        read -e -p "$prompt" result
    fi
    echo "${result:-$default}"
}

# Проверка, является ли IP локальным
check_if_local() {
    local ip=$1
    if [[ "$ip" == "127.0.0.1" || "$ip" == "localhost" ]]; then
        return 0
    fi
    
    # Получаем свои IP
    local my_ips
    my_ips=$(hostname -I)
    if [[ "$my_ips" == *"$ip"* ]]; then
        return 0
    fi
    
    return 1
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
    if [ -z "$NODE_DOMAIN" ]; then echo "❌ Домен обязателен."; exit 1; fi
    
    NODE_SECRET=$(safe_read "🔑 SECRET_KEY ноды (из Панели): " "")
    if [ -z "$NODE_SECRET" ]; then echo "❌ Ключ обязателен."; exit 1; fi
    
    # 2. Выбор стратегии сертификатов
    echo ""
    printf "%b\n" "${C_BOLD}[ 2. ОТКУДА БЕРЕМ СЕРТИФИКАТЫ? ]${C_RESET}"
    echo "   [1] ☁️  Cloudflare API (Wildcard, нужен Токен)"
    echo "   [2] 📥 Скопировать с сервера Панели (SSH/Local)"
    echo "   [3] 📂 Локальные файлы (уже лежат в $CERT_DIR)"
    
    CERT_STRATEGY=$(safe_read "Твой выбор (1-3): " "2")
    
    # 3. Доп. данные
    case "$CERT_STRATEGY" in
        1) 
            echo ""
            printf "%b\n" "${C_YELLOW}--- Настройки Cloudflare ---${C_RESET}"
            CF_TOKEN=$(safe_read "API Token (Edit Zone DNS): " "")
            CF_EMAIL=$(safe_read "Email аккаунта CF: " "")
            if [[ -z "$CF_TOKEN" || -z "$CF_EMAIL" ]]; then echo "❌ Данные CF обязательны."; exit 1; fi
            ;;
        2) 
            echo ""
            printf "%b\n" "${C_YELLOW}--- Данные сервера с Панелью ---${C_RESET}"
            PANEL_IP=$(safe_read "IP Панели (или localhost): " "")
            if [ -z "$PANEL_IP" ]; then echo "❌ IP обязателен."; exit 1; fi
            
            if check_if_local "$PANEL_IP"; then
                IS_LOCAL_PANEL=1
                printf "%b\n" "${C_GREEN}✅ Обнаружена локальная установка. SSH не нужен.${C_RESET}"
            else
                IS_LOCAL_PANEL=0
                PANEL_PORT=$(safe_read "SSH Порт Панели: " "22")
                PANEL_USER=$(safe_read "User (Enter = root): " "root")
                echo "🔐 Введи пароль root от Панели:"
                read -s -p "Пароль: " PANEL_PASS
                echo ""
                
                # ПРОВЕРКА СВЯЗИ СРАЗУ
                echo ""
                printf "%b" "📡 Проверяю коннект к Панели... "
                if ! command -v sshpass &>/dev/null; then apt-get update -qq && apt-get install -y -qq sshpass >/dev/null; fi
                
                if sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "$PANEL_PORT" "$PANEL_USER@$PANEL_IP" exit 2>/dev/null; then
                    printf "%b\n" "${C_GREEN}OK!${C_RESET}"
                else
                    printf "%b\n" "${C_RED}ОШИБКА!${C_RESET}"
                    echo "Не могу подключиться к $PANEL_IP:$PANEL_PORT. Проверь пароль и порт."
                    exit 1
                fi
            fi
            ;;
        3) 
            echo "ℹ️  Убедись, что файлы fullchain.pem и privkey.pem лежат в $CERT_DIR"
            sleep 2
            ;;
        *) echo "❌ Неверный выбор."; exit 1 ;;
    esac
    
    echo ""
    printf "%b\n" "${C_GREEN}✅ Данные валидны. Начинаем установку...${C_RESET}"
    sleep 1
}

# ============================================================ #
#                     ИНСТРУМЕНТЫ                              #
# ============================================================ #
install_dependencies() {
    echo ""
    printf "%b" "🔧 Проверяю инструменты... "
    export DEBIAN_FRONTEND=noninteractive
    local pkgs="curl wget unzip jq socat git cron sshpass"
    if ! command -v socat &>/dev/null || ! command -v sshpass &>/dev/null; then
        run_cmd apt-get update -qq >/dev/null 2>&1
        run_cmd apt-get install -y -qq $pkgs >/dev/null 2>&1
    fi
    printf "%b\n" "${C_GREEN}OK.${C_RESET}"
    
    if ! command -v docker &> /dev/null; then
        printf "%b" "🐳 Ставлю Docker... "
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        printf "%b\n" "${C_GREEN}Готово.${C_RESET}"
    else
        printf "🐳 Docker уже на борту. %bOK.%b\n" "${C_GREEN}" "${C_RESET}"
    fi
}

# ============================================================ #
#                     SSL СЕРТИФИКАТЫ                          #
# ============================================================ #
setup_certificates() {
    mkdir -p "$CERT_DIR"
    echo ""
    printf "%b\n" "${C_CYAN}🔒 Настройка SSL ($NODE_DOMAIN)...${C_RESET}"

    case $CERT_STRATEGY in
        1) # Cloudflare (Оставляем как было, там всё ок)
            echo "🚀 Ставлю acme.sh..."
            curl -s https://get.acme.sh | sh -s email="$CF_EMAIL" >/dev/null 2>&1
            export CF_Token="$CF_TOKEN"; export CF_Email="$CF_EMAIL"
            echo "🔑 Выпускаю сертификат..."
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$NODE_DOMAIN" -d "*.$NODE_DOMAIN" --force >/dev/null 2>&1
            ~/.acme.sh/acme.sh --install-cert -d "$NODE_DOMAIN" \
                --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" \
                --reloadcmd "docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode" >/dev/null 2>&1
            ;;
            
        2) # Panel (Локал или SSH)
            local FOUND_PATH=""
            # Возможные пути сертификатов
            local PATHS=(
                "/root/.acme.sh/${NODE_DOMAIN}_ecc"
                "/root/.acme.sh/${NODE_DOMAIN}"
                "/etc/letsencrypt/live/${NODE_DOMAIN}"
            )

            echo "🔎 Ищу сертификаты для $NODE_DOMAIN..."

            if [ $IS_LOCAL_PANEL -eq 1 ]; then
                # --- ЛОКАЛЬНЫЙ ПОИСК ---
                for p in "${PATHS[@]}"; do
                    if [[ -f "$p/fullchain.pem" || -f "$p/fullchain.cer" ]]; then FOUND_PATH="$p"; break; fi
                done
                
                if [ -z "$FOUND_PATH" ]; then
                    echo "❌ Не нашел файлы локально. Укажи путь вручную:"
                    read -e -p "Путь: " FOUND_PATH
                fi
                
                echo "📂 Копирую из $FOUND_PATH..."
                cp "$FOUND_PATH/fullchain."* "$CERT_DIR/fullchain.pem"
                cp "$FOUND_PATH/"*key* "$CERT_DIR/privkey.pem"
                
                # Крон для локала
                (crontab -l 2>/dev/null; echo "0 3 * * 1 cp $FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem && cp $FOUND_PATH/*key* $CERT_DIR/privkey.pem && docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode") | crontab -
                
            else
                # --- SSH ПОИСК ---
                for rpath in "${PATHS[@]}"; do
                    if sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -p "$PANEL_PORT" "$PANEL_USER@$PANEL_IP" "[ -f $rpath/fullchain.pem ] || [ -f $rpath/fullchain.cer ]" 2>/dev/null; then
                        FOUND_PATH="$rpath"
                        break
                    fi
                done
                
                if [ -z "$FOUND_PATH" ]; then
                    echo "❌ Авто-поиск не дал результатов."
                    echo "Введи полный путь к папке с сертификатами на Панели:"
                    read -p "Путь: " FOUND_PATH
                fi
                
                echo "📥 Качаю из $FOUND_PATH..."
                sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.*" "$CERT_DIR/fullchain.pem" >/dev/null 2>&1
                sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/*key*" "$CERT_DIR/privkey.pem" >/dev/null 2>&1
                
                # Крон для SSH
                local CRON_CMD="sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem && sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/*key* $CERT_DIR/privkey.pem && docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode"
                (crontab -l 2>/dev/null; echo "0 3 * * 1 $CRON_CMD") | crontab -
            fi
            
            echo "✅ Сертификаты получены и настроено авто-обновление."
            ;;
            
        3) # Local files
            # Check done in main
            ;;
    esac

    if [[ ! -f "$CERT_DIR/fullchain.pem" || ! -f "$CERT_DIR/privkey.pem" ]]; then
        echo "❌ Ошибка: Файлы не появились в $CERT_DIR"
        exit 1
    fi
    chmod 644 "$CERT_DIR/"*
}

# ============================================================ #
#                     САЙТ-МАСКИРОВКА                          #
# ============================================================ #
setup_fake_site_script() {
    echo "🎭 Настраиваю сайт-хамелеон (Port 8080)..."
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
    (crontab -l 2>/dev/null; echo "0 4 */15 * * $ROTATE_SCRIPT") | crontab -
    echo "✅ Сайт установлен."
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
    hostname: remnanode
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
    echo "🔥 Запускаю сервисы..."
    cd "$INSTALL_DIR" || exit
    docker compose up -d --remove-orphans --force-recreate >/dev/null 2>&1
    
    sleep 3
    if docker ps | grep -q "remnanode"; then
        printf "%b\n" "${C_GREEN}✅ НОДА УСПЕШНО ЗАПУЩЕНА!${C_RESET}"
        echo "------------------------------------------------"
        echo "   Домен: $NODE_DOMAIN"
        echo "   Xray:  Порт 443"
        echo "   Nginx: Порт 8080 (Сайт)"
        echo "------------------------------------------------"
        echo "👉 Настрой в панели профиль с путями:"
        echo "   /cert/fullchain.pem, /cert/privkey.pem"
    else
        printf "%b\n" "${C_RED}❌ Ошибка запуска.${C_RESET}"
    fi
}

# MAIN
collect_data
install_dependencies
setup_certificates
setup_fake_site_script
deploy_docker