#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ УСТАНОВКИ REMNAWAVE NODE (ULTRA SECURE)       ==
# ==        VLESS-WS-TLS + MIMICRY + SMART CERT             ==
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
SMART_RENEW_SCRIPT="/usr/local/bin/reshala-smart-renew"
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
#                     УДАЛЕНИЕ (С УМОМ)                        #
# ============================================================ #
uninstall_node() {
    echo ""
    echo "🧨 Останавливаю и удаляю контейнеры..."
    if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        cd "$INSTALL_DIR" && docker compose down -v 2>/dev/null
    fi
    rm -rf "$INSTALL_DIR"
    rm -f "$CRON_FILE"
    rm -f "$ROTATE_SCRIPT"
    rm -f "$SMART_RENEW_SCRIPT"
    
    echo ""
    printf "%b\n" "${C_YELLOW}🔐 УПРАВЛЕНИЕ СЕРТИФИКАТАМИ${C_RESET}"
    echo "Нода удалена. Что делать с сертификатами SSL?"
    
    # Ищем сертификаты в Let's Encrypt
    local le_certs=($(ls -d /etc/letsencrypt/live/*/ 2>/dev/null))
    # Ищем локальные копии
    local local_certs=($(ls "$CERT_DIR"/*.pem 2>/dev/null))

    if [ ${#le_certs[@]} -eq 0 ] && [ ${#local_certs[@]} -eq 0 ]; then
        echo "   (Сертификаты не найдены, чистить нечего)"
    else
        echo "   [1] 🛡️  ОСТАВИТЬ ВСЁ (Безопасно)"
        echo "   [2] 🗑️  Удалить ТОЛЬКО копии ноды ($CERT_DIR)"
        
        if [ ${#le_certs[@]} -gt 0 ]; then
            echo "   [3] ☢️  Выбрать и удалить сертификат Certbot (из системы)"
        fi
        
        local del_choice=$(safe_read "Твой выбор: " "1")
        
        case "$del_choice" in
            1) echo "🆗 Сертификаты не тронуты.";;
            2) 
                rm -rf "$CERT_DIR"
                echo "✅ Папка $CERT_DIR удалена."
                ;;
            3)
                echo ""
                echo "Список сертификатов Certbot:"
                local i=1
                for cert in "${le_certs[@]}"; do
                    local domain_name=$(basename "$cert")
                    echo "   [$i] $domain_name"
                    ((i++))
                done
                echo "   [a] Удалить ВСЕ"
                echo "   [c] Отмена"
                
                local cert_num=$(safe_read "Номер для удаления: " "c")
                
                if [[ "$cert_num" == "a" ]]; then
                    rm -rf /etc/letsencrypt/live/*
                    rm -rf /etc/letsencrypt/archive/*
                    rm -rf /etc/letsencrypt/renewal/*
                    echo "🗑️ Все сертификаты Certbot удалены."
                elif [[ "$cert_num" =~ ^[0-9]+$ ]] && [ "${le_certs[$((cert_num-1))]}" ]; then
                    local target_domain=$(basename "${le_certs[$((cert_num-1))]}")
                    certbot delete --cert-name "$target_domain" --non-interactive 2>/dev/null || rm -rf "/etc/letsencrypt/live/$target_domain"
                    echo "🗑️ Сертификат для $target_domain удален."
                fi
                
                # И копии тоже зачистим
                rm -rf "$CERT_DIR"
                ;;
        esac
    fi
    
    echo ""
    printf "%b\n" "${C_GREEN}✅ Нода полностью удалена.${C_RESET}"
    exit 0
}

check_existing_installation() {
    if [ -d "$INSTALL_DIR" ] || docker ps | grep -q "remnanode"; then
        clear
        printf "%b\n" "${C_RED}╔═════════════════════════════════════════════════════════════════╗${C_RESET}"
        printf "%b\n" "${C_RED}║         ⚠️  ВНИМАНИЕ! ОБНАРУЖЕНА АКТИВНАЯ НОДА! ⚠️              ║${C_RESET}"
        printf "%b\n" "${C_RED}╚═════════════════════════════════════════════════════════════════╝${C_RESET}"
        echo ""
        echo "В папке $INSTALL_DIR уже есть файлы или работает контейнер."
        echo "Что будем делать?"
        echo ""
        
        printf "   [1] %b🧨 СНЕСТИ И ПЕРЕУСТАНОВИТЬ С НУЛЯ%b\n" "${C_RED}${C_BOLD}" "${C_RESET}"
        echo "       -> Полное удаление текущей ноды, ключей и конфигов."
        echo "       -> Выбор нового домена и метода SSL."
        echo "       -> Подойдет, если всё сломалось и нужно начисто."
        echo ""
        
        printf "   [2] %b♻️  ОБНОВИТЬ КОНФИГУРАЦИЮ (SOFT UPDATE)%b\n" "${C_GREEN}${C_BOLD}" "${C_RESET}"
        echo "       -> Пересоздаст Docker Compose с новыми настройками."
        echo "       -> Сохранит текущие сертификаты и SECRET_KEY."
        echo "       -> Подойдет для обновления версии или фикса багов."
        echo ""
        
        printf "   [3] %b🗑️  УДАЛИТЬ НОДУ (UNINSTALL)%b\n" "${C_YELLOW}" "${C_RESET}"
        echo "       -> Просто удалит всё и почистит следы."
        echo ""
        
        echo "   [b] 🔙 Отмена (Ничего не трогать)"
        echo "-------------------------------------------------------------------"
        
        local choice=$(safe_read "Твой выбор: " "b")
        case "$choice" in
            1) 
                echo ""
                echo "🧨 Принято. Начинаю полную зачистку..."
                if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
                    cd "$INSTALL_DIR" && docker compose down -v 2>/dev/null
                fi
                # Удаляем всё, кроме бэкапов (если вдруг решим делать)
                rm -rf "$INSTALL_DIR"
                rm -f "$CRON_FILE"
                rm -f "$ROTATE_SCRIPT"
                rm -f "$SMART_RENEW_SCRIPT"
                echo "✅ Старая нода уничтожена. Начинаем установку..."
                sleep 1
                # Скрипт пойдет дальше выполнять collect_data
                ;;
            2)
                echo ""
                echo "🔧 Режим мягкого обновления..."
                # Здесь мы можем попытаться вытащить старые данные, чтобы не спрашивать снова
                if grep -q "SECRET_KEY=" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
                    NODE_SECRET=$(grep "SECRET_KEY=" "$INSTALL_DIR/docker-compose.yml" | cut -d= -f2)
                    echo "✅ Найден старый ключ."
                fi
                if grep -q "server_name" "$INSTALL_DIR/nginx.conf" 2>/dev/null; then
                    NODE_DOMAIN=$(grep "server_name" "$INSTALL_DIR/nginx.conf" | awk '{print $3}')
                    echo "✅ Найден домен: $NODE_DOMAIN"
                fi
                
                # Если нашли данные - пропускаем сбор, идем сразу к деплою
                if [[ -n "$NODE_SECRET" && -n "$NODE_DOMAIN" ]]; then
                    echo "🚀 Пересобираю контейнеры..."
                    setup_fake_site # Обновим скрипты ротации на всякий
                    deploy_docker   # Пересоздадим docker-compose
                    exit 0
                else
                    echo "⚠️ Не удалось прочитать старый конфиг. Придется вводить данные заново."
                fi
                ;;
            3) 
                uninstall_node
                exit 0 
                ;;
            *) 
                echo "Отмена."
                exit 0 
                ;;
        esac
    fi
}

# ============================================================ #
#                     СБОР ИНФОРМАЦИИ                          #
# ============================================================ #
collect_data() {
    clear
    printf "%b\n" "${C_CYAN}🚀 УСТАНОВКА REMNAWAVE NODE${C_RESET}"
    
    printf "%b\n" "${C_BOLD}[ 1. НАСТРОЙКИ НОДЫ ]${C_RESET}"
    NODE_DOMAIN=$(safe_read "🌐 Домен ноды (напр. tr1.site.com): " "")
    [[ -z "$NODE_DOMAIN" ]] && { echo "❌ Домен нужен."; exit 1; }
    
    NODE_SECRET=$(safe_read "🔑 SECRET_KEY ноды (из Панели): " "")
    [[ -z "$NODE_SECRET" ]] && { echo "❌ Ключ нужен."; exit 1; }
    
    # ПРОВЕРКА СУЩЕСТВУЮЩИХ СЕРТИФИКАТОВ
    local existing_cert=0
    if [[ -f "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" ]]; then existing_cert=1; fi
    if [[ -f "$CERT_DIR/fullchain.pem" ]]; then existing_cert=1; fi
    
    if [ $existing_cert -eq 1 ]; then
        echo ""
        printf "%b\n" "${C_GREEN}✅ Найдены существующие сертификаты для $NODE_DOMAIN!${C_RESET}"
        read -p "Использовать их? (y/n): " use_exist
        if [[ "$use_exist" == "y" || "$use_exist" == "Y" ]]; then
            # Пытаемся понять, откуда они взялись
            if [[ -f "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" ]]; then
                CERT_STRATEGY="3" # Считаем, что это Certbot
            else
                CERT_STRATEGY="EXISTING_LOCAL"
            fi
            return
        fi
    fi
    
    echo ""
    printf "%b\n" "${C_BOLD}[ 2. СЕРТИФИКАТЫ (SSL) ]${C_RESET}"
    echo "   [1] ☁️  Cloudflare API (Wildcard)"
    echo "   [2] 📥 Скопировать с Панели (Умное авто-копирование)"
    echo "   [3] 🆕 Выпустить Certbot Standalone (Умное продление)"
    echo "   [4] 📂 Локальные файлы (в $CERT_DIR)"
    
    CERT_STRATEGY=$(safe_read "Выбор (1-4): " "1")
    
    case "$CERT_STRATEGY" in
        1) 
            printf "%b\n" "${C_YELLOW}--- Cloudflare ---${C_RESET}"
            CF_TOKEN=$(safe_read "Token: " "")
            CF_EMAIL=$(safe_read "Email: " "")
            ;;
        2)
            printf "%b\n" "${C_YELLOW}--- Panel ---${C_RESET}"
            PANEL_IP=$(safe_read "IP Панели: " "")
            [[ "$PANEL_IP" == "127.0.0.1" || "$PANEL_IP" == "localhost" || "$PANEL_IP" == "$(hostname -I | awk '{print $1}')" ]] && IS_LOCAL_PANEL=1
            if [ $IS_LOCAL_PANEL -eq 0 ]; then
                PANEL_PORT=$(safe_read "SSH Порт: " "22")
                PANEL_USER=$(safe_read "User: " "root")
                read -s -p "Пароль root: " PANEL_PASS; echo ""
                if ! command -v sshpass &>/dev/null; then apt-get update -qq && apt-get install -y -qq sshpass; fi
                if ! sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "$PANEL_PORT" "$PANEL_USER@$PANEL_IP" exit 2>/dev/null; then
                    echo "❌ Ошибка соединения!"; exit 1
                fi
            fi
            ;;
        3) echo "ℹ️  Порт 80 будет временно открыт для выпуска.";;
        4) echo "ℹ️  Положи файлы в $CERT_DIR."; sleep 2;;
    esac
}

# ============================================================ #
#                     СИСТЕМНАЯ НАСТРОЙКА                      #
# ============================================================ #
setup_system() {
    echo ""
    printf "%b" "🔧 Ставлю софт... "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq curl wget unzip jq socat git cron sshpass ufw certbot openssl >/dev/null
    if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sh >/dev/null; fi
    printf "%b\n" "${C_GREEN}OK${C_RESET}"

    # Firewall
    echo "🛡️ Настройка Firewall..."
    if ! command -v ufw &>/dev/null; then apt-get install -y ufw >/dev/null; fi
    
    local ssh_p=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    ssh_p=${ssh_p:-22}
    
    # Базовые правила
    ufw allow "$ssh_p"/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw allow 2222/tcp >/dev/null 2>&1 # API Ноды
    
    # Закрываем 80 по дефолту
    ufw delete allow 80/tcp >/dev/null 2>&1
    
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >/dev/null
    else
        ufw reload >/dev/null
    fi
}

# ============================================================ #
#                     СЕРТИФИКАТЫ (SMART LOGIC)                #
# ============================================================ #
setup_certificates() {
    mkdir -p "$CERT_DIR"
    local RELOAD_CMD="docker compose -f $INSTALL_DIR/docker-compose.yml restart remnanode"

    if [[ "$CERT_STRATEGY" == "EXISTING_LOCAL" ]]; then
        # Если выбрали использовать существующие локальные файлы, просто проверяем
        if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
             # Если они в letsencrypt, копируем
             cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
             cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
        fi
        echo "♻️  Сертификаты готовы."
    else
        case $CERT_STRATEGY in
            1) # Cloudflare (acme.sh)
                if [ ! -d "/root/.acme.sh" ]; then curl https://get.acme.sh | sh -s email="$CF_EMAIL" >/dev/null 2>&1; fi
                export CF_Token="$CF_TOKEN"; export CF_Email="$CF_EMAIL"
                /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$NODE_DOMAIN" -d "*.$NODE_DOMAIN" --force
                /root/.acme.sh/acme.sh --install-cert -d "$NODE_DOMAIN" --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "$RELOAD_CMD"
                ;;
            
            2) # Panel Copy (MANUAL SELECTION)
                echo "📥 Подключаюсь к Панели для поиска сертификатов..."
                
                # 1. Сканируем удаленные пути (Let's Encrypt и Acme.sh)
                # Используем ls -d, чтобы получить список папок
                local RAW_LIST
                if [ $IS_LOCAL_PANEL -eq 1 ]; then
                    RAW_LIST=$(ls -d /etc/letsencrypt/live/* /root/.acme.sh/*_ecc /root/.acme.sh/* 2>/dev/null)
                else
                    # Экранируем * для удаленного shell
                    RAW_LIST=$(sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no -p "$PANEL_PORT" "$PANEL_USER@$PANEL_IP" "ls -d /etc/letsencrypt/live/* /root/.acme.sh/*_ecc /root/.acme.sh/* 2>/dev/null")
                fi

                # 2. Фильтруем мусор (файлы .conf, ca и т.д.) и собираем массив
                local OPTIONS=()
                local i=1
                echo ""
                echo "🔎 Найдены сертификаты на Панели:"
                echo "---------------------------------------------------"
                
                for p in $RAW_LIST; do
                    # Игнорируем системные файлы acme.sh
                    if [[ "$p" == *"http.header"* || "$p" == *"ca.conf"* || "$p" == *"account.conf"* ]]; then continue; fi
                    # Проверяем, есть ли внутри файлы ключей (грубая проверка по имени папки)
                    # (Можно усложнить, но это замедлит работу по SSH)
                    
                    OPTIONS+=("$p")
                    echo "   [$i] $p"
                    ((i++))
                done
                
                if [ ${#OPTIONS[@]} -eq 0 ]; then
                    echo "❌ На Панели не найдено папок с сертификатами!"
                    echo "Проверь пути /etc/letsencrypt/live и /root/.acme.sh"
                    read -e -p "Введи путь вручную: " FOUND_PATH
                else
                    echo "---------------------------------------------------"
                    echo "   [m] Ввести путь вручную"
                    local choice
                    read -p "Выбери сертификат (номер): " choice
                    
                    if [[ "$choice" == "m" ]]; then
                        read -e -p "Введи полный путь: " FOUND_PATH
                    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "${OPTIONS[$((choice-1))]}" ]; then
                        FOUND_PATH="${OPTIONS[$((choice-1))]}"
                    else
                        echo "❌ Неверный выбор."; exit 1
                    fi
                fi

                echo "✅ Выбран путь: $FOUND_PATH"
                echo "📥 Копирую..."

                # Скрипт обновления (Smart Renew)
                cat <<EOF > "$SMART_RENEW_SCRIPT"
#!/bin/bash
CERT="$CERT_DIR/fullchain.pem"
NEED_RENEW=0

if [ ! -f "\$CERT" ]; then
    echo "Сертификата нет."
    NEED_RENEW=1
else
    if openssl x509 -checkend \$(( 7 * 86400 )) -noout -in "\$CERT"; then
        echo "Сертификат валиден."
        NEED_RENEW=0
    else
        echo "Срок истекает!"
        NEED_RENEW=1
    fi
fi

if [ "\$NEED_RENEW" -eq 1 ]; then
    echo "Копирую с Панели ($FOUND_PATH)..."
EOF

                # Генерация команд копирования
                if [ $IS_LOCAL_PANEL -eq 1 ]; then
                    # Local
                    cp -L "$FOUND_PATH/fullchain."* "$CERT_DIR/fullchain.pem" 2>/dev/null
                    cp -L "$FOUND_PATH/"*key* "$CERT_DIR/privkey.pem" 2>/dev/null
                    # В скрипт обновления
                    echo "    cp -L $FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem" >> "$SMART_RENEW_SCRIPT"
                    echo "    cp -L $FOUND_PATH/*key* $CERT_DIR/privkey.pem" >> "$SMART_RENEW_SCRIPT"
                else
                    # SSH
                    # Сначала пробуем скопировать сейчас, чтобы убедиться что работает
                    # Ищем fullchain (он может быть .pem или .cer)
                    sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.*" "$CERT_DIR/fullchain.pem" 2>/dev/null
                    # Ищем ключ (privkey.pem или domain.key)
                    sshpass -p "$PANEL_PASS" scp -P "$PANEL_PORT" -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_IP:$FOUND_PATH/*key*" "$CERT_DIR/privkey.pem" 2>/dev/null
                    
                    # В скрипт обновления
                    echo "    sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/fullchain.* $CERT_DIR/fullchain.pem" >> "$SMART_RENEW_SCRIPT"
                    echo "    sshpass -p '$PANEL_PASS' scp -P $PANEL_PORT -o StrictHostKeyChecking=no $PANEL_USER@$PANEL_IP:$FOUND_PATH/*key* $CERT_DIR/privkey.pem" >> "$SMART_RENEW_SCRIPT"
                fi

                # Финализация скрипта
                cat <<EOF >> "$SMART_RENEW_SCRIPT"
    chmod 644 $CERT_DIR/*
    $RELOAD_CMD
    echo "Обновлено."
fi
EOF
                chmod +x "$SMART_RENEW_SCRIPT"
                
                # Добавляем в Cron
                echo "0 3 * * * root $SMART_RENEW_SCRIPT >> /var/log/cert-renew.log 2>&1" > "$CRON_FILE"
                ;;
            
            3) # Certbot Standalone (SMART PORT)
                echo "🆕 Настройка Certbot с хуками..."
                
                # Скрипт не нужен, Certbot сам умный, если использовать хуки
                # Но первый выпуск делаем вручную с открытием порта
                
                echo "🔓 Открываю 80..."
                ufw allow 80/tcp >/dev/null
                systemctl stop nginx 2>/dev/null
                docker stop remnawave-nginx 2>/dev/null
                
                certbot certonly --standalone -d "$NODE_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
                
                if [ -f "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" ]; then
                    cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
                    cp -L "/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
                else
                    echo "❌ Ошибка Certbot."; ufw delete allow 80/tcp >/dev/null; exit 1
                fi
                
                echo "🔒 Закрываю 80..."
                ufw delete allow 80/tcp >/dev/null
                
                # Команда обновления с хуками
                # pre-hook: Открыть порт, остановить Nginx
                # post-hook: Закрыть порт, запустить Nginx, скопировать файлы, рестарт ноды
                
                cat <<EOF > "$SMART_RENEW_SCRIPT"
#!/bin/bash
certbot renew --non-interactive \\
  --pre-hook "ufw allow 80/tcp; docker stop remnawave-nginx" \\
  --post-hook "ufw delete allow 80/tcp; docker start remnawave-nginx; cp -L /etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem $CERT_DIR/fullchain.pem; cp -L /etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem $CERT_DIR/privkey.pem; $RELOAD_CMD"
EOF
                chmod +x "$SMART_RENEW_SCRIPT"
                
                # Cron (2 раза в день, Certbot сам решит, пора ли обновлять)
                echo "0 3,15 * * * root $SMART_RENEW_SCRIPT >> /var/log/cert-renew.log 2>&1" > "$CRON_FILE"
                ;;
        esac
    fi
    
    if [[ ! -s "$CERT_DIR/fullchain.pem" ]]; then echo "❌ Файлы сертификатов пусты!"; exit 1; fi
    chmod 644 "$CERT_DIR/"*
}

setup_fake_site() {
    echo "🎭 Настройка сайта-хамелеона..."
    cat << 'EOF' > "$ROTATE_SCRIPT"
#!/bin/bash
SITE_DIR="/var/www/html"
TEMP_DIR="/tmp/website_template"
URLS=("https://www.free-css.com/assets/files/free-css-templates/download/page296/healet.zip" "https://www.free-css.com/assets/files/free-css-templates/download/page296/carvilla.zip" "https://www.free-css.com/assets/files/free-css-templates/download/page296/oxer.zip")
RANDOM_URL=${URLS[$RANDOM % ${#URLS[@]}]}
rm -rf "$TEMP_DIR" "$SITE_DIR"/*; mkdir -p "$TEMP_DIR" "$SITE_DIR"
wget -q -O "$TEMP_DIR/template.zip" "$RANDOM_URL"
unzip -q "$TEMP_DIR/template.zip" -d "$TEMP_DIR"
CONTENT_DIR=$(find "$TEMP_DIR" -name "index.html" | head -n 1 | xargs dirname)
if [ -n "$CONTENT_DIR" ]; then cp -r "$CONTENT_DIR"/* "$SITE_DIR/"; fi
rm -rf "$TEMP_DIR"
chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || chmod -R 755 "$SITE_DIR"
EOF
    chmod +x "$ROTATE_SCRIPT"
    bash "$ROTATE_SCRIPT" >/dev/null 2>&1
    echo "0 4 1,15 * * root $ROTATE_SCRIPT >> /var/log/site-rotate.log 2>&1" >> "$CRON_FILE"
}

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

    echo "🔥 Запуск..."
    cd "$INSTALL_DIR" && docker compose up -d --remove-orphans --force-recreate >/dev/null 2>&1
    sleep 5
    if docker ps | grep -q "remnanode"; then
        printf "%b\n" "${C_GREEN}✅ НОДА УСТАНОВЛЕНА И ЗАЩИЩЕНА!${C_RESET}"
        echo "   SSL: Умное обновление настроено."
        echo "   FW:  Порт 80 закрыт (открывается только при продлении)."
    else
        printf "%b\n" "${C_RED}❌ Ошибка запуска.${C_RESET}"
    fi
}

# MAIN
check_existing_installation
collect_data
setup_system
setup_certificates
setup_fake_site
deploy_docker