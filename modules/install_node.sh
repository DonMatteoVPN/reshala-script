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

# --- Глобальные переменные конфигурации ---
NODE_DOMAIN=""
NODE_SECRET=""
CERT_STRATEGY="" # 1=CF, 2=Panel, 3=Local
PANEL_IP=""
PANEL_USER="root"
PANEL_PASS=""
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

# ============================================================ #
#                     СБОР ИНФОРМАЦИИ (В НАЧАЛЕ)               #
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
    echo "   [2] 📥 Скопировать с сервера Панели (SSH)"
    echo "   [3] 📂 Локальные файлы (уже лежат в $CERT_DIR)"
    
    CERT_STRATEGY=$(safe_read "Твой выбор (1-3): " "2")
    
    # 3. Доп. данные в зависимости от выбора
    case "$CERT_STRATEGY" in
        1) # Cloudflare
            echo ""
            printf "%b\n" "${C_YELLOW}--- Настройки Cloudflare ---${C_RESET}"
            CF_TOKEN=$(safe_read "API Token (Edit Zone DNS): " "")
            CF_EMAIL=$(safe_read "Email аккаунта CF: " "")
            if [[ -z "$CF_TOKEN" || -z "$CF_EMAIL" ]]; then echo "❌ Данные CF обязательны."; exit 1; fi
            ;;
        2) # Panel SSH
            echo ""
            printf "%b\n" "${C_YELLOW}--- Данные сервера с Панелью ---${C_RESET}"
            PANEL_IP=$(safe_read "IP Панели: " "")
            PANEL_USER=$(safe_read "User (Enter = root): " "root")
            echo "🔐 Введи пароль root от Панели (для копирования сертификатов):"
            read -s -p "Пароль: " PANEL_PASS
            echo ""
            if [ -z "$PANEL_IP" ]; then echo "❌ IP Панели обязателен."; exit 1; fi
            ;;
        3) # Local
            echo "ℹ️  Убедись, что файлы fullchain.pem и privkey.pem лежат в $CERT_DIR"
            sleep 2
            ;;
        *) echo "❌ Неверный выбор."; exit 1 ;;
    esac
    
    echo ""
    printf "%b\n" "${C_GREEN}✅ Данные собраны. Начинаем установку...${C_RESET}"
    sleep 1
}

# ============================================================ #
#                     УСТАНОВКА ПО                             #
# ============================================================ #

install_dependencies() {
    echo ""
    printf "%b" "🔧 Проверяю инструменты и зависимости... "
    local pkgs="curl wget unzip jq socat git cron sshpass"
    
    # Тихая установка
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v socat &>/dev/null || ! command -v sshpass &>/dev/null; then
        run_cmd apt-get update -qq >/dev/null 2>&1
        run_cmd apt-get install -y -qq $pkgs >/dev/null 2>&1
        printf "%b\n" "${C_GREEN}Установлены.${C_RESET}"
    else
        printf "%b\n" "${C_GREEN}OK.${C_RESET}"
    fi
    
    # Docker
    if ! command -v docker &> /dev/null; then
        printf "%b" "🐳 Docker не найден. Устанавливаю (это займет время)... "
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        printf "%b\n" "${C_GREEN}Готово.${C_RESET}"
    else
        printf "🐳 Docker уже стоит. %bOK.%b\n" "${C_GREEN}" "${C_RESET}"
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
        1) # Cloudflare
            echo "🚀 Ставлю acme.sh..."
            curl -s https://get.acme.sh | sh -s email="$CF_EMAIL" >/dev/null 2>&1
            
            export CF_Token="$CF_TOKEN"
            export CF_Email="$CF_EMAIL"
            
            echo "🔑 Выпускаю сертификат (DNS API)..."
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$NODE_DOMAIN" -d "*.$NODE_DOMAIN" --force >/dev/null 2>&1
            
            echo "💾 Устанавливаю сертификаты..."
            ~/.acme.sh/acme.sh --install-cert -d "$NODE_DOMAIN" \
                --key-file       "$CERT_DIR/privkey.pem"  \
                --fullchain-file "$CERT_DIR/fullchain.pem" \
                --reloadcmd     "docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode" >/dev/null 2>&1
            ;;
            
        2) # Panel SSH (Воровство)
            echo "📥 Копирую сертификаты с $PANEL_IP..."
            
            # Определяем путь (спрашиваем удаленно или перебираем)
            # Попробуем "умный" перебор удаленных путей
            local REMOTE_PATHS=(
                "/root/.acme.sh/${NODE_DOMAIN}_ecc"
                "/root/.acme.sh/${NODE_DOMAIN}"
                "/etc/letsencrypt/live/${NODE_DOMAIN}"
            )
            
            local FOUND_PATH=""
            
            # Пробуем найти правильный путь
            for rpath in "${REMOTE_PATHS[@]}"; do
                if sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP" "[ -f $rpath/fullchain.pem ] || [ -f $rpath/fullchain.cer ]" 2>/dev/null; then
                    FOUND_PATH="$rpath"
                    break
                fi
            done
            
            # Если не нашли автоматически, предлагаем меню (как ты хотел красиво)
            if [ -z "$FOUND_PATH" ]; then
                echo ""
                printf "%b\n" "${C_YELLOW}⚠️  Авто-поиск сертификата не дал результата.${C_RESET}"
                echo "Где на Панели лежат сертификаты?"
                echo "   [1] acme.sh (ECC) -> root/.acme.sh/${NODE_DOMAIN}_ecc"
                echo "   [2] acme.sh (RSA) -> root/.acme.sh/${NODE_DOMAIN}"
                echo "   [3] Certbot       -> /etc/letsencrypt/live/${NODE_DOMAIN}"
                local path_choice=$(safe_read "Выбор: " "1")
                
                case $path_choice in
                    1) FOUND_PATH="/root/.acme.sh/${NODE_DOMAIN}_ecc" ;;
                    2) FOUND_PATH="/root/.acme.sh/${NODE_DOMAIN}" ;;
                    3) FOUND_PATH="/etc/letsencrypt/live/${NODE_DOMAIN}" ;;
                esac
            fi
            
            printf "   👉 Источник: %b%s%b\n" "${C_CYAN}" "$FOUND_PATH" "${C_RESET}"
            
            # Копируем (fullchain)
            sshpass -p "$PANEL_PASS" scp -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.*" "$CERT_DIR/fullchain.pem" >/dev/null 2>&1
            
            # Копируем (key) - имена могут быть разные (.key, .pem)
            sshpass -p "$PANEL_PASS" scp -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/*.key" "$CERT_DIR/privkey.pem" 2>/dev/null
            if [ ! -f "$CERT_DIR/privkey.pem" ]; then
                 # Если не нашлось .key, пробуем .pem (acme хранит как domain.key, certbot privkey.pem)
                 sshpass -p "$PANEL_PASS" scp -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/*key.pem" "$CERT_DIR/privkey.pem" >/dev/null 2>&1
            fi
            
            # Настройка CRON для авто-воровства
            local CRON_CMD="sshpass -p '$PANEL_PASS' scp -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem && sshpass -p '$PANEL_PASS' scp -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/*.key $CERT_DIR/privkey.pem && docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode"
            (crontab -l 2>/dev/null; echo "0 3 * * 1 $CRON_CMD") | crontab -
            echo "✅ Добавлено авто-обновление сертификатов (Cron)."
            ;;
            
        3) # Local
            # Ничего не делаем, файлы должны быть
            ;;
    esac

    # Финальная проверка
    if [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]]; then
        chmod 644 "$CERT_DIR/"*
        printf "%b\n" "${C_GREEN}✅ Сертификаты установлены успешно.${C_RESET}"
    else
        printf "%b\n" "${C_RED}❌ Ошибка: Файлы сертификатов не найдены в $CERT_DIR.${C_RESET}"
        exit 1
    fi
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
    echo "✅ Сайт установлен. Ротация включена."
}

# ============================================================ #
#                     ЗАПУСК КОНТЕЙНЕРОВ                       #
# ============================================================ #
deploy_docker() {
    mkdir -p "$INSTALL_DIR"
    
    # Docker Compose
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
      options:
        max-size: '30m'
        max-file: '5'

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
      options:
        max-size: '30m'
        max-file: '5'
EOF

    # Nginx Config (Port 8080)
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
        echo "   Xray:  Слушает порт 443"
        echo "   Nginx: Слушает порт 8080 (Fallback)"
        echo "------------------------------------------------"
        echo "👉 В ПАНЕЛИ настрой профиль на использование путей:"
        echo "   Certificate: /cert/fullchain.pem"
        echo "   Key:         /cert/privkey.pem"
        echo "   Fallback:    Dest 8080"
    else
        printf "%b\n" "${C_RED}❌ Ошибка запуска. Проверь логи: docker logs remnanode${C_RESET}"
    fi
}

# ============================================================ #
#                          MAIN                                #
# ============================================================ #
collect_data
install_dependencies
setup_certificates
setup_fake_site_script
deploy_docker