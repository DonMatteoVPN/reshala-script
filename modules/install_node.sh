#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ УСТАНОВКИ БОЕВОЙ НОДЫ (VLESS-WS-TLS-MIMIC)    ==
# ==             SPECIAL FOR REMNAWAVE PANEL                ==
# ============================================================ #

# --- Цвета (Импортируем стиль Решалы) ---
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

# --- Утилиты ---
run_cmd() { 
    if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# ============================================================ #
#                     ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ                  #
# ============================================================ #

install_dependencies() {
    echo "🔧 Проверяю инструменты..."
    local pkgs="curl wget unzip jq socat git cron"
    if ! command -v socat &>/dev/null; then
        printf "%b\n" "${C_YELLOW}📦 Ставлю зависимости (socat, unzip, git)...${C_RESET}"
        run_cmd apt-get update -qq
        run_cmd apt-get install -y -qq $pkgs
    fi
}

# Генерация рандомного шаблона сайта
setup_fake_site_script() {
    echo "🎭 Настраиваю механизм смены масок (Fake Site)..."
    
    # Создаем скрипт ротации
    cat << 'EOF' > "$ROTATE_SCRIPT"
#!/bin/bash
# --- RESHALA SITE ROTATOR ---
SITE_DIR="/var/www/html"
TEMP_DIR="/tmp/website_template"
URLS=(
    "https://www.free-css.com/assets/files/free-css-templates/download/page296/healet.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page296/carvilla.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page296/oxer.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page295/antique-cafe.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page293/fitapp.zip"
    "https://www.free-css.com/assets/files/free-css-templates/download/page294/topic.zip"
)

# Выбираем рандомный
RANDOM_URL=${URLS[$RANDOM % ${#URLS[@]}]}

echo "Downloading: $RANDOM_URL"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
mkdir -p "$SITE_DIR"

wget -q -O "$TEMP_DIR/template.zip" "$RANDOM_URL"
unzip -q "$TEMP_DIR/template.zip" -d "$TEMP_DIR"

# Ищем папку с index.html
CONTENT_DIR=$(find "$TEMP_DIR" -name "index.html" | head -n 1 | xargs dirname)

if [ -n "$CONTENT_DIR" ]; then
    rm -rf "${SITE_DIR:?}"/*
    cp -r "$CONTENT_DIR"/* "$SITE_DIR/"
    echo "Site updated successfully."
else
    echo "Error: Could not find template content."
fi

# Чистим
rm -rf "$TEMP_DIR"
# Ставим права
chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || chmod -R 755 "$SITE_DIR"
EOF

    chmod +x "$ROTATE_SCRIPT"
    
    # Запускаем один раз прямо сейчас
    echo "🏗️ Качаю первый сайт-легенду..."
    bash "$ROTATE_SCRIPT"
    
    # Добавляем в Cron (раз в 15 дней)
    # 0 4 */15 * * -> В 4:00 утра, каждые 15 дней
    (crontab -l 2>/dev/null; echo "0 4 */15 * * $ROTATE_SCRIPT") | crontab -
    echo "✅ Авто-смена маски настроена (каждые 2 недели)."
}

# ============================================================ #
#                     SSL СЕРТИФИКАТЫ                          #
# ============================================================ #

setup_certificates() {
    local domain=$1
    mkdir -p "$CERT_DIR"

    clear
    printf "%b\n" "${C_CYAN}🔒 ВОПРОС БЕЗОПАСНОСТИ (SSL)${C_RESET}"
    echo "Откуда берем сертификаты для домена ${C_BOLD}$domain${C_RESET}?"
    echo ""
    echo "   [1] ☁️  Cloudflare API (Нужен Token, поддерживает Wildcard)"
    echo "   [2] 📥 Скопировать с Панели (Если у тебя Wildcard на другом сервере)"
    echo "   [3] 📂 У меня уже есть файлы (Я сам закинул в $CERT_DIR)"
    echo ""
    read -p "Твой выбор: " cert_choice

    case $cert_choice in
        1)
            # --- ACME.SH + CLOUDFLARE ---
            echo ""
            echo "Иди в Cloudflare -> My Profile -> API Tokens -> Create Token -> Edit Zone DNS."
            read -p "Введи CF_Token: " cf_token
            read -p "Введи Email аккаунта CF: " cf_email
            
            if [ -z "$cf_token" ]; then echo "❌ Токена нет, кина не будет."; exit 1; fi
            
            echo "🚀 Ставлю acme.sh..."
            curl https://get.acme.sh | sh -s email="$cf_email"
            
            export CF_Token="$cf_token"
            export CF_Email="$cf_email"
            
            echo "🔑 Выпускаю сертификат через DNS API..."
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" -d "*.$domain" --force
            
            echo "💾 Устанавливаю сертификаты в $CERT_DIR..."
            ~/.acme.sh/acme.sh --install-cert -d "$domain" \
                --key-file       "$CERT_DIR/privkey.pem"  \
                --fullchain-file "$CERT_DIR/fullchain.pem" \
                --reloadcmd     "docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode"
            
            if [ -f "$CERT_DIR/privkey.pem" ]; then
                printf "%b\n" "${C_GREEN}✅ Сертификат получен и настроен авто-выпуск!${C_RESET}"
            else
                printf "%b\n" "${C_RED}❌ Ошибка выпуска. Смотри логи выше.${C_RESET}"
                exit 1
            fi
            ;;
            
        2)
            # --- КОПИРОВАНИЕ ПО SSH ---
            echo ""
            echo "Введи данные сервера, ГДЕ СТОИТ ПАНЕЛЬ (и лежат сертификаты):"
            read -p "IP Панели: " panel_ip
            read -p "User (обычно root): " panel_user
            panel_user=${panel_user:-root}
            
            # Проверка sshpass
            if ! command -v sshpass &>/dev/null; then apt-get install -y sshpass; fi
            
            echo "Пробую подключиться..."
            # Ищем, где там лежат сертификаты (обычно acme.sh или certbot)
            # Предполагаем acme.sh путь по умолчанию для root, либо /etc/letsencrypt
            
            echo "Откуда копировать?"
            echo "1) Из папки acme.sh (root/.acme.sh/${domain}_ecc)"
            echo "2) Из Let's Encrypt (/etc/letsencrypt/live/$domain)"
            read -p "Выбор: " copy_source
            
            local remote_path=""
            if [ "$copy_source" == "1" ]; then
                remote_path="/root/.acme.sh/${domain}_ecc"
            else
                remote_path="/etc/letsencrypt/live/$domain"
            fi
            
            echo "🔐 Введи пароль от $panel_ip:"
            scp -r "$panel_user@$panel_ip:$remote_path/fullchain.pem" "$CERT_DIR/"
            scp -r "$panel_user@$panel_ip:$remote_path/privkey.pem" "$CERT_DIR/" # Или .key
            
            # Если .key называется по-другому
            if [ ! -f "$CERT_DIR/privkey.pem" ]; then
                 scp -r "$panel_user@$panel_ip:$remote_path/$domain.key" "$CERT_DIR/privkey.pem"
            fi
            
            if [ -f "$CERT_DIR/privkey.pem" ]; then
                printf "%b\n" "${C_GREEN}✅ Украли сертификат успешно.${C_RESET}"
                
                # Создаем крон на обновление (тупо копируем раз в неделю)
                echo "0 3 * * 1 scp $panel_user@$panel_ip:$remote_path/fullchain.pem $CERT_DIR/ && scp $panel_user@$panel_ip:$remote_path/*key.pem $CERT_DIR/privkey.pem && docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode" > /tmp/cert_cron
                crontab -l 2>/dev/null | cat - /tmp/cert_cron | crontab -
                echo "✅ Добавил авто-обновление (воровство) в Cron."
            else
                printf "%b\n" "${C_RED}❌ Не удалось скопировать. Проверь пути.${C_RESET}"
                exit 1
            fi
            ;;
            
        3)
            echo "Ок, проверяю $CERT_DIR..."
            if [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]]; then
                echo "✅ Файлы на месте."
            else
                echo "❌ Пусто. Закинь файлы fullchain.pem и privkey.pem в $CERT_DIR и запускай заново."
                exit 1
            fi
            ;;
    esac
    
    # Даем права на чтение (на всякий случай)
    chmod 644 "$CERT_DIR/"*
}

# ============================================================ #
#                     ГЛАВНАЯ УСТАНОВКА                        #
# ============================================================ #

main_install() {
    clear
    printf "%b\n" "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    printf "%b\n" "${C_CYAN}║        🚀 УСТАНОВКА REMNAWAVE NODE (VLESS-WS-TLS)            ║${C_RESET}"
    printf "%b\n" "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    
    # 1. Проверка Docker
    if ! command -v docker &> /dev/null; then
        echo "🐳 Docker не найден. Ставлю..."
        curl -fsSL https://get.docker.com | sh
    fi

    # 2. Сбор данных
    read -p "🌐 Введи ДОМЕН для этой ноды (например, tr1.site.com): " NODE_DOMAIN
    if [ -z "$NODE_DOMAIN" ]; then echo "❌ Без домена никак."; exit 1; fi
    
    read -p "🔑 Введи SECRET_KEY ноды (из Панели): " NODE_SECRET
    if [ -z "$NODE_SECRET" ]; then echo "❌ Без ключа не подключимся."; exit 1; fi

    install_dependencies
    
    # 3. Сертификаты
    setup_certificates "$NODE_DOMAIN"
    
    # 4. Сайт-заглушка
    setup_fake_site_script
    
    # 5. Создание Docker Compose
    mkdir -p "$INSTALL_DIR"
    cat <<EOF > "$INSTALL_DIR/docker-compose.yml"
services:
  # --- САЙТ-ХАМЕЛЕОН (NGINX) ---
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
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

  # --- БОЕВАЯ НОДА (XRAY) ---
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
      # Проброс сертификатов внутрь Xray
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

    # 6. Конфиг Nginx (Слушает 8080)
    cat <<EOF > "$INSTALL_DIR/nginx.conf"
server {
    listen 8080;
    listen [::]:8080;
    server_name 127.0.0.1 localhost ${NODE_DOMAIN};

    root /var/www/html;
    index index.html;

    access_log off;
    
    # Маскировка 404
    error_page 404 /index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

    # 7. Запуск
    echo ""
    echo "🔥 Запускаю двигатели..."
    cd "$INSTALL_DIR" || exit
    docker compose up -d --remove-orphans --force-recreate
    
    echo ""
    echo "⏳ Проверка статуса..."
    sleep 5
    if docker ps | grep -q "remnanode"; then
        printf "%b\n" "${C_GREEN}✅ Нода запущена успешно!${C_RESET}"
        echo "-----------------------------------------------------"
        echo "📊 Статус:"
        echo "   - Xray: Слушает порт 443 (TLS/WS)"
        echo "   - Nginx: Слушает порт 8080 (Сайт-маска)"
        echo "   - Certs: $CERT_DIR (Авто-обновление вкл)"
        echo "   - Site:  Авто-ротация каждые 15 дней"
        echo "-----------------------------------------------------"
        echo "👉 Теперь иди в ПАНЕЛЬ и настрой профиль VLESS-WS-TLS-OFFICIAL"
        echo "   Fallback Dest: 8080"
        echo "   Cert Path: /cert/fullchain.pem, /cert/privkey.pem"
    else
        printf "%b\n" "${C_RED}❌ Что-то пошло не так. Проверь логи: docker logs remnanode${C_RESET}"
    fi
}

# Запуск
main_install