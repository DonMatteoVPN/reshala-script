#!/bin/bash
# ============================================================ #
# ==   МОДУЛЬ: УСТАНОВКА ПАНЕЛИ REMNAWAVE (HIGH-LOAD)       ==
# ==   Загружается динамически из GitHub                    ==
# ============================================================ #

# --- Цвета ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m';

# --- Константы ---
INSTALL_DIR="/opt/remnawave"
NGINX_CONF_DIR="/etc/nginx"
MINIAPP_DIR="/opt/remnawave-bedolaga-telegram-bot/miniapp"

# --- Функции ---
run_cmd() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
log() { echo -e "${C_CYAN}[RESHALA-MODULE]${C_RESET} $1"; }
error() { echo -e "${C_RED}[ERROR] $1${C_RESET}"; exit 1; }

# --- Проверка зависимостей ---
check_dependencies() {
    log "🔍 Проверяю инструменты..."
    local missing=0
    if ! command -v docker &> /dev/null; then echo "❌ Docker не найден."; missing=1; fi
    if ! command -v nginx &> /dev/null; then echo "❌ Nginx не найден."; missing=1; fi
    if ! command -v certbot &> /dev/null; then echo "❌ Certbot не найден."; missing=1; fi
    if ! command -v htpasswd &> /dev/null; then 
        echo "⚠️ Нет утилиты для хешей. Ставлю apache2-utils..."
        run_cmd apt-get update -q && run_cmd apt-get install -y apache2-utils -q
    fi
    if [ $missing -eq 1 ]; then error "Сначала установи базу (Docker, Nginx, Certbot)."; fi
}

# --- Генерация хеша для TinyAuth ---
generate_tinyauth_hash() {
    local user="$1"
    local pass="$2"
    htpasswd -nB -C 10 "$user" "$pass" | cut -d ":" -f 2
}

# --- Основная логика ---
main_install() {
    clear
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_CYAN}║     УСТАНОВКА ПАНЕЛИ REMNAWAVE (HIGH-LOAD EDITION)           ║${C_RESET}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    
    check_dependencies

    # 1. Сбор данных
    echo -e "${C_YELLOW}--- НАСТРОЙКА ДОМЕНОВ ---${C_RESET}"
    read -p "Введи свой ГЛАВНЫЙ домен (например, donmatteo.monster): " MAIN_DOMAIN
    if [[ -z "$MAIN_DOMAIN" ]]; then error "Домен не может быть пустым!"; fi

    echo -e "\n${C_YELLOW}--- НАСТРОЙКА TINYAUTH (ЗАЩИТА) ---${C_RESET}"
    read -p "Придумай логин для входа (TinyAuth): " TA_USER
    read -s -p "Придумай пароль для входа: " TA_PASS
    echo ""
    
    log "🔐 Генерирую секреты..."
    TA_HASH=$(generate_tinyauth_hash "$TA_USER" "$TA_PASS")
    TA_SECRET=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    JWT_SECRET=$(openssl rand -hex 32)
    API_SECRET=$(openssl rand -hex 32)
    WEBHOOK_SECRET=$(openssl rand -hex 32)
    
    log "📂 Создаю папки..."
    run_cmd mkdir -p "$INSTALL_DIR"
    run_cmd mkdir -p "$MINIAPP_DIR/myredirect"

    # 2. Создание docker-compose.yml
    log "📝 Пишу docker-compose.yml..."
    cat <<EOF > "$INSTALL_DIR/docker-compose.yml"
x-base: &base
  image: remnawave/backend:latest
  restart: always
  env_file:
    - .env
  networks:
    - remnawave-network
  logging:
    driver: 'json-file'
    options: { max-size: '25m', max-file: '4' }

services:
  api:
    <<: *base
    network_mode: "service:remnawave-scheduler"
    networks: {}
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-api'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
      remnawave-scheduler: { condition: service_healthy }

  remnawave-scheduler:
    <<: *base
    container_name: 'remnawave-scheduler'
    hostname: remnawave-scheduler
    entrypoint: ['/bin/sh', 'docker-entrypoint.sh']
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-scheduler'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
    ports:
      - '127.0.0.1:3000:3000'
      - '127.0.0.1:3001:3001'
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

  remnawave-processor:
    <<: *base
    container_name: 'remnawave-processor'
    hostname: remnawave-processor
    command: 'pm2-runtime start ecosystem.config.js --env production --only remnawave-jobs'
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
      remnawave-scheduler: { condition: service_healthy }

  remnawave-db:
    image: postgres:17.6
    container_name: 'remnawave-db'
    hostname: remnawave-db
    restart: always
    env_file: [ .env ]
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 10s
      timeout: 5s
      retries: 5

  remnawave-redis:
    image: valkey/valkey:8.1.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    networks:
      - remnawave-network
    volumes:
      - remnawave-redis-data:/data
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 10s
      timeout: 5s
      retries: 5

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave-scheduler:3000
      - APP_PORT=3010
      - META_TITLE=Ваша подписка на VPN
      - META_DESCRIPTION=Свобода и безопасность одним касанием!
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }
    volumes:
      - ./myapp-config.json:/opt/app/frontend/assets/app-config.json:ro

  remnawave-mini-app:
    image: ghcr.io/maposia/remnawave-telegram-sub-mini-app:latest
    container_name: remnawave-telegram-mini-app
    hostname: remnawave-telegram-mini-app
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3020:3020'
    networks:
      - remnawave-network
    volumes:
       - ./myapp-config.json:/app/public/assets/app-config.json:ro

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    volumes:
      - /etc/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /opt/remnawave-bedolaga-telegram-bot:/opt/remnawave-bedolaga-telegram-bot:ro
    network_mode: host
    depends_on:
      - api
      - remnawave-subscription-page
      - remnawave-mini-app
    logging:
      driver: 'journald'
      options:
        tag: "nginx.remnawave"

  tinyauth:
    image: ghcr.io/maposia/remnawave-tinyauth:latest
    container_name: tinyauth
    hostname: tinyauth
    restart: always
    ports:
      - '127.0.0.1:3002:3002'
    networks:
      - remnawave-network
    environment:
      - PORT=3002
      - APP_URL=https://auth.$MAIN_DOMAIN
      - USERS=$TA_USER:$TA_HASH
      - SECRET=$TA_SECRET
    logging:
      driver: 'json-file'
      options: { max-size: '10m', max-file: '3' }

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge

volumes:
  remnawave-db-data:
  remnawave-redis-data:
EOF

    # 3. Создание .env
    log "📝 Пишу .env..."
    read -p "Введи Telegram Bot Token: " TG_BOT_TOKEN
    read -p "Введи Chat ID для уведомлений: " TG_CHAT_ID
    
    cat <<EOF > "$INSTALL_DIR/.env"
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
REDIS_HOST=remnawave-redis
REDIS_PORT=6379
JWT_AUTH_SECRET=$JWT_SECRET
JWT_API_TOKENS_SECRET=$API_SECRET
JWT_AUTH_LIFETIME=168
IS_TELEGRAM_NOTIFICATIONS_ENABLED=true
TELEGRAM_BOT_TOKEN=$TG_BOT_TOKEN
TELEGRAM_NOTIFY_USERS_CHAT_ID=$TG_CHAT_ID
TELEGRAM_NOTIFY_NODES_CHAT_ID=$TG_CHAT_ID
TELEGRAM_NOTIFY_CRM_CHAT_ID=$TG_CHAT_ID
TELEGRAM_OAUTH_ENABLED=true
TELEGRAM_OAUTH_ADMIN_IDS=[]
FRONT_END_DOMAIN=panrem.$MAIN_DOMAIN
SUB_PUBLIC_DOMAIN=subrem.$MAIN_DOMAIN
IS_DOCS_ENABLED=false
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
METRICS_USER=admin
METRICS_PASS=admin
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://hooks.$MAIN_DOMAIN/webhook
WEBHOOK_SECRET_HEADER=$WEBHOOK_SECRET
HWID_DEVICE_LIMIT_ENABLED=false
HWID_FALLBACK_DEVICE_LIMIT=3
HWID_MAX_DEVICES_ANNOUNCE="Вы использовали максимальное количество устройств."
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=true
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80, 95]
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"
REMNAWAVE_PANEL_URL=http://remnawave-scheduler:3000
REMNAWAVE_TOKEN=
BUY_LINK=https://t.me/DonMatteo_VPN_bot
AUTH_API_KEY=
REDIRECT_LINK=https://subapp.$MAIN_DOMAIN/myredirect/?telegram&redirect_to=
EOF

    # 4. Создание myapp-config.json (ПОЛНЫЙ)
    log "📝 Заливаю конфиг приложений (myapp-config.json)..."
    # Используем 'EOF' в кавычках, чтобы bash не пытался интерпретировать переменные внутри JSON
    cat <<'EOF' > "$INSTALL_DIR/myapp-config.json"
{
  "config": {
    "additionalLocales": [
      "ru"
    ],
    "branding": {
      "logoUrl": "https://lh3.googleusercontent.com/rd-d/ALs6j_FQxFkowBZNSpfISvbAX-ynoZUwhkF2w5ELfknE_gH7yGcsP2hvwoFvW4Aj9dqtz6FVtAkHPl8oo3-Ps9WVcLrtE2YVGV357AfqktJAoyeotXYB01GzngQHyUa5kDfFbJKz8P0zENgAEY63Ak4VEsp4imasl0DCfR_FDcomFVjOyoejE9T8m90TzTo0m8PFw_ZXjDK5MbOpF9HV2q4SLWO2DIkYwoUJcyH_qE0toH4KAGzpmHfYk0DnRZ1Z4JPkZUroPcPXppX9G9F5fGowfeIWReyXw0aSy8D9BvNfA7duAQzXtG7IG1Uf8dY20cNw6b5DEsDKYoryu3Fd8PP54dkBp3ferYsaNmgWCOjNjLTYETqBWgJFfqwLQT9DoXSG7oA0eYY_p1wvllLhfObcYJlMlKcpkKOf291uMmYPz__gJYqOJ23trMResj5j4u_uMyoIIRrI4jF84D4ycklM6C_VJMRREjJtGbvaU47GdRvVtyqVziRtD6g3x24Kj1PiTa3cWPe8Rlnr2hC-YOnL6jBH5fPAB_N2LcwoSwarFM0gA8WRRKfujTna6XDM7xc3x6h5s2DglNiSfdcT0gPQxdmSR4MqPvWz9HZd5WNkH3LQUkDTd7-5NX6yrhvuB-l444Y1b5EE8GTYedLNifncKoh4w4cInlf5eaFyrEAcMlDbm_aeoSOsuTP1uLUyqu48NHyNxiwXLCPgdVQJYqXszr2BImiuzCWvUhzsK_MSnU7OM6bhtRr-i465Z-pFCIXyaye4mBE4PaUxnWk9CMqEyyYYTyf0jMjtNVhz8G1k_dhzOMuR5fiNexvN9e7vk6DfUGQAZUxPB-Xt4rdbyUnaZGumpU1RLldVlqrRtEWPrjo9AWHJfiKmhogKrI2CgifF_09Y2RKGWVhrey4xvYsnGoMTa9BF3uxuHUV7dOXM7CmhJyiXkskQlq6NdsJ8ZeSXptNMkdjWmWuttxsre9Xs_7HdNjZsSEaEAUYX2gPUjXBPUM_xrMnBs60M1v6ugG2W27gwb69F5bZ6GOH83_3WoaR5ycRQX4I5GgTd39uSBaQZuQ=w1809-h921?auditContext=forDisplay",
      "name": "DonMatteo VPN",
      "supportUrl": "https://t.me/DonMatteo_Support_bot"
    }
  },
  "platforms": {
    "ios": [
      {
        "id": "clash-mi",
        "name": "Clash Mi",
        "isFeatured": true,
        "urlScheme": "clash://install-config?overwrite=no&name=🛡️🚀 DonMatteoVPN&url=",
        "installationStep": {
          "buttons": [
            {
              "buttonLink": "https://apps.apple.com/ru/app/clash-mi/id6744321968",
              "buttonText": {
                "en": "Download from the RU App Store",
                "ru": "Скачать с RU App Store"
              }
            },
            {
              "buttonLink": "https://apps.apple.com/us/app/clash-mi/id6744321968",
              "buttonText": {
                "en": "Download from the Global App Store",
                "ru": "Скачать с Global App Store"
              }
            }
          ],
          "description": {
            "en": "1. Open the App Store page and install the app. \n2. Launch it, in the VPN configuration permissions window, click Allow\n3. Enter your phone password.\n4. Come back here after installation.",
            "ru": "1. Откройте страницу в App Store и установите приложение. \n2. Запустите его, в окне разрешения VPN-конфигурации нажмите Allow\n3. Введите свой пароль от телефона.\n4. Вернитесь после установки сюда."
          }
        },
        "addSubscriptionStep": {
          "description": {
            "en": "5. Tap the button below — the app will open and the subscription will be added automatically.",
            "ru": "5. Нажмите кнопку ниже — приложение откроется, и подписка добавится автоматически."
          }
        },
        "connectAndUseStep": {
          "description": {
            "en": "6. On the main page, click the Disconnected button in the permissions window that appears. \nVPN configurations, click Allow and enter your password to connect to the VPN.",
            "ru": "6. На главной странице нажми кнопку Disconnected,  в появившемся окне разрешения \nVPN-конфигурации нажмите Allow и введите свой пароль для подключения к VPN."
          }
        }
      }
    ],
    "android": [
      {
        "id": "flclash",
        "name": "FlClashX",
        "isFeatured": true,
        "urlScheme": "flclash://install-config?url=",
        "installationStep": {
          "buttons": [
            {
              "buttonLink": "http://n8n-chevereto-8d6daa-193-23-216-20.traefik.me/images/2025/11/17/d0d7f25caa51fb667f64b63db9203cc3.mp4",
              "buttonText": {
                "en": "🎞 VIDEO INSTRUCTIONS 👁‍🗨",
                "ru": "🎞 ВИДЕО ИНСТРУКЦИЯ 👁‍🗨"
              }
            },
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-android-arm64-v8a.apk",
              "buttonText": {
                "en": "Download APK (arm64-v8a)",
                "ru": "Скачать APK (arm64-v8a)"
              }
            },
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-android-armeabi-v7a.apk",
              "buttonText": {
                "en": "Download APK (armeabi-v7a)",
                "ru": "Скачать APK (armeabi-v7a)"
              }
            },
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-android-x86_64.apk",
              "buttonText": {
                "en": "Download APK (x86_64)",
                "ru": "Скачать APK (x86_64)"
              }
            }
          ],
          "description": {
            "en": "1. Download the FlClash APK and install it. \n2. Launch the app and grant all permissions.\n3. Come back here after installation.\n    DO YOU KNOW WHICH FILE TO DOWNLOAD? SEE BELOW!!",
            "ru": "1. Скачайте FlClash APK и установите. \n2. Запустите приложение и дайте все разрешения.\n3. Вернитесь после установки сюда.\n    ЕСЛИ СЛОЖНО, СМОТРИТЕ ВИДЕО ИНСТРУКЦИЮ 👇👇"
          }
        },
        "addSubscriptionStep": {
          "description": {
            "en": "4. Click the button below to add a subscription.",
            "ru": "4. Нажмите кнопку ниже, чтобы добавить подписку"
          }
        },
        "additionalAfterAddSubscriptionStep": {
          "buttons": [],
          "title": {
            "en": "If the subscription is not added",
            "ru": "Если подписка не добавилась"
          },
          "description": {
            "en": "5. If nothing happens after clicking on the button, add the subscription manually. \n    Click the Get Link button in the upper-right corner of this page and copy the link. \n    In FlClash, go to the Profiles section, click the + button, select the URL,\n    paste your copied link and click Send.",
            "ru": "5. Если после нажатия на кнопку ничего не произошло, добавьте подписку вручную. \n    Нажмите на этой страницу кнопку Получить ссылку в правом верхнем углу, скопируйте ссылку. \n    В FlClash перейдите в раздел Профили, нажмите кнопку +, выберите URL, \n    вставьте вашу скопированную ссылку и нажмите Отправить."
          }
        },
        "connectAndUseStep": {
          "description": {
            "en": "6. Select the added profile in the Profiles section. \n    In the Control Panel, click the enable button in the lower-right corner. \n    After launching, in the Proxy section, you can change the choice of the server you are connected to. \n    connect and choose a connection for the available services at your discretion!\n\nChapter  \"PROXY\" 🛡️ Via VPN is the main tab.\n   Example:\nLet's say you need Discord to always work through Germany.\n• Click on the 💬 Discord group.\n• Select 🇩🇪 Germany from the drop-down list.\n\nReady! Now all other traffic will go through the server selected in 🛡️ Via VPN,\n and Discord — strictly through Germany.",
            "ru": "6. Выберите добавленный профиль в разделе Профили. \n    В Панели управления нажмите кнопку включить в правом нижнем углу. \n    После запуска в разделе Прокси вы можете изменить выбор сервера к которому вас \n    подключить и выбрать подключение для доступных сервисов на свое усмотрение!\n\nРаздел  \"ПРОКСИ\" 🛡️ Через VPN - основная вкладка.\n   Пример:\nПредположим, вам нужно, чтобы именно Discord всегда работал через Германию.\n• Нажмите на группу 💬 Discord.\n• В раскрывшемся списке выберите 🇩🇪 Германия.\n\nГотово! Теперь весь остальной трафик будет идти через сервер выбранный в 🛡️ Через VPN,\n а Discord — строго через Германию."
          }
        },
        "additionalBeforeAddSubscriptionStep": {
          "title": {
            "en": "How to determine which APK to download!",
            "ru": "Как определить какой APK качать?"
          },
          "description": {
            "en": "3.1. Download DevCheck Device & System Info, \n3.2. Launch and go to the \"SPECIFICATIONS\" section\n3.3. In the \"ARCHITECTURE\" column, the item ABI and Supported ABIs\n       They specify the format that suits you.",
            "ru": "3.1. Качаем DevCheck Device & System Info, \n3.2. Запустить и перейти в раздел \"ХАРАКТЕРИСТИКИ\"\n3.3. В графе \"АРХИТЕКТУРА\" пункт ABI и Поддерживаемые ABI\n       В них указан формат который вам подойдет."
          },
          "buttons": [
            {
              "buttonLink": "https://play.google.com/store/apps/details?id=flar2.devcheck",
              "buttonText": {
                "en": "Download System Info on Google Play",
                "ru": "Скачать System Info в Google Play"
              }
            }
          ]
        }
      }
    ],
    "linux": [
      {
        "id": "flclash",
        "name": "FlClashX",
        "isFeatured": true,
        "urlScheme": "flclash://install-config?url=",
        "installationStep": {
          "buttons": [
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-linux-amd64.AppImage",
              "buttonText": {
                "en": "Download Linux (AppImage x64)",
                "ru": "Скачать Linux (AppImage x64)"
              }
            },
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-linux-amd64.deb",
              "buttonText": {
                "en": "Download Linux (DebPackage x64)",
                "ru": "Скачать Linux (DebPackage x64)"
              }
            },
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-linux-amd64.rpm",
              "buttonText": {
                "en": "Download Linux (RpmPackage x64)",
                "ru": "Скачать Linux (RpmPackage x64)"
              }
            }
          ],
          "description": {
            "en": "1. Download the required version of FlClash and install it. \n2. Launch the application.\n3. Come back here after installation.",
            "ru": "1. Скачайте FlClash нужной версии и установите. \n2. Запустите приложение.\n3. Вернитесь после установки сюда."
          }
        },
        "addSubscriptionStep": {
          "description": {
            "en": "4. Click the button below to add subscription",
            "ru": "4. Нажмите кнопку ниже, чтобы добавить подписку"
          }
        },
        "additionalAfterAddSubscriptionStep": {
          "buttons": [],
          "title": {
            "en": "If the subscription is not added",
            "ru": "Если подписка не добавилась"
          },
          "description": {
            "en": "5. If nothing happens after clicking on the button, add the subscription manually. \n    Click the Get Link button in the upper-right corner of this page and copy the link. \n    In FlClash, go to the Profiles section, click the + button, select the URL, paste your \n    copy the link and click Send",
            "ru": "5. Если после нажатия на кнопку ничего не произошло, добавьте подписку вручную. \n    Нажмите на этой страницу кнопку Получить ссылку в правом верхнем углу, скопируйте ссылку. \n    В FlClash перейдите в раздел Профили, нажмите кнопку +, выберите URL, вставьте вашу \n    скопированную ссылку и нажмите Отправить"
          }
        },
        "connectAndUseStep": {
          "description": {
            "en": "6. Select the added profile in the Profiles section. \n    In the Control Panel, click the enable button in the lower-right corner. \n    After launching, in the Proxy section, you can change the choice of the server you are connected to. \n    connect and choose a connection for the available services at your discretion!\n\nChapter  \"PROXY\" 🛡️ Via VPN is the main tab.\n   Example:\nLet's say you need Discord to always work through Germany.\n• Click on the 💬 Discord group.\n• Select 🇩🇪 Germany from the drop-down list.\n\nReady! Now all other traffic will go through the server selected in 🛡️ Via VPN,\n and Discord — strictly through Germany.",
            "ru": "6. Выберите добавленный профиль в разделе Профили. \n    В Панели управления нажмите кнопку включить в правом нижнем углу. \n    После запуска в разделе Прокси вы можете изменить выбор сервера к которому вас \n    подключить и выбрать подключение для доступных сервисов на свое усмотрение!\n\nРаздел  \"ПРОКСИ\" 🛡️ Через VPN - основная вкладка.\n   Пример:\nПредположим, вам нужно, чтобы именно Discord всегда работал через Германию.\n• Нажмите на группу 💬 Discord.\n• В раскрывшемся списке выберите 🇩🇪 Германия.\n\nГотово! Теперь весь остальной трафик будет идти через сервер выбранный в 🛡️ Через VPN,\n а Discord — строго через Германию."
          }
        }
      }
    ],
    "macos": [
      {
        "id": "flclash",
        "name": "FlClashX",
        "isFeatured": true,
        "urlScheme": "flclash://install-config?url=",
        "installationStep": {
          "buttons": [
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-macos-arm64.dmg",
              "buttonText": {
                "en": "Download macOS (Apple Silicon)",
                "ru": "Скачать macOS (Apple Silicon)"
              }
            },
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-macos-amd64.dmg",
              "buttonText": {
                "en": "Download macOS (Intel X64)",
                "ru": "Скачать macOS (Intel X64)"
              }
            }
          ],
          "description": {
            "en": "1. Download the required version of FlClash and install it. \n2. Launch the application.\n3. Come back here after installation.",
            "ru": "1. Скачайте FlClash нужной версии и установите. \n2. Запустите приложение.\n3. Вернитесь после установки сюда."
          }
        },
        "addSubscriptionStep": {
          "description": {
            "en": "4. Click the button below to add subscription",
            "ru": "4. Нажмите кнопку ниже, чтобы добавить подписку"
          }
        },
        "additionalAfterAddSubscriptionStep": {
          "buttons": [],
          "title": {
            "en": "If the subscription is not added",
            "ru": "Если подписка не добавилась"
          },
          "description": {
            "en": "5. If nothing happens after clicking on the button, add the subscription manually. \n    Click the Get Link button in the upper-right corner of this page and copy the link. \n    In FlClash, go to the Profiles section, click the + button, select the URL, paste your \n    copy the link and click Send",
            "ru": "5. Если после нажатия на кнопку ничего не произошло, добавьте подписку вручную. \n    Нажмите на этой страницу кнопку Получить ссылку в правом верхнем углу, скопируйте ссылку. \n    В FlClash перейдите в раздел Профили, нажмите кнопку +, выберите URL, вставьте вашу \n    скопированную ссылку и нажмите Отправить"
          }
        },
        "connectAndUseStep": {
          "description": {
            "en": "6. Select the added profile in the Profiles section. \n    In the Control Panel, click the enable button in the lower-right corner. \n    After launching, in the Proxy section, you can change the choice of the server you are connected to. \n    connect and choose a connection for the available services at your discretion!\n\nChapter  \"PROXY\" 🛡️ Via VPN is the main tab.\n   Example:\nLet's say you need Discord to always work through Germany.\n• Click on the 💬 Discord group.\n• Select 🇩🇪 Germany from the drop-down list.\n\nReady! Now all other traffic will go through the server selected in 🛡️ Via VPN,\n and Discord — strictly through Germany.",
            "ru": "6. Выберите добавленный профиль в разделе Профили. \n    В Панели управления нажмите кнопку включить в правом нижнем углу. \n    После запуска в разделе Прокси вы можете изменить выбор сервера к которому вас \n    подключить и выбрать подключение для доступных сервисов на свое усмотрение!\n\nРаздел  \"ПРОКСИ\" 🛡️ Через VPN - основная вкладка.\n   Пример:\nПредположим, вам нужно, чтобы именно Discord всегда работал через Германию.\n• Нажмите на группу 💬 Discord.\n• В раскрывшемся списке выберите 🇩🇪 Германия.\n\nГотово! Теперь весь остальной трафик будет идти через сервер выбранный в 🛡️ Через VPN,\n а Discord — строго через Германию."
          }
        }
      }
    ],
    "windows": [
      {
        "id": "flclash",
        "name": "FlClashX",
        "isFeatured": true,
        "urlScheme": "flclash://install-config?url=",
        "installationStep": {
          "buttons": [
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-windows-amd64-setup.exe",
              "buttonText": {
                "en": "Download for Windows (Setup)",
                "ru": "Скачать Windows (Setup)"
              }
            }
          ],
          "description": {
            "en": "1. Download FlClash and install it. \n2. Launch the application.\n3. Come back here after installation.",
            "ru": "1. Скачайте FlClash и установите. \n2. Запустите приложение.\n3. Вернитесь после установки сюда."
          }
        },
        "addSubscriptionStep": {
          "description": {
            "en": "4. Click the button below to add subscription",
            "ru": "4. Нажмите кнопку ниже, чтобы добавить подписку"
          }
        },
        "additionalAfterAddSubscriptionStep": {
          "buttons": [],
          "title": {
            "en": "If the subscription is not added",
            "ru": "Если подписка не добавилась"
          },
          "description": {
            "en": "5. If nothing happens after clicking on the button, add the subscription manually. \n    Click the Get Link button in the upper-right corner of this page and copy the link. \n    In FlClash, go to the Profiles section, click the + button, select the URL, paste your \n    copy the link and click Send",
            "ru": "5. Если после нажатия на кнопку ничего не произошло, добавьте подписку вручную. \n    Нажмите на этой страницу кнопку Получить ссылку в правом верхнем углу, скопируйте ссылку. \n    В FlClash перейдите в раздел Профили, нажмите кнопку +, выберите URL, вставьте вашу \n    скопированную ссылку и нажмите Отправить"
          }
        },
        "connectAndUseStep": {
          "description": {
            "en": "6. Select the added profile in the Profiles section. \n    In the Control Panel, click the enable button in the lower-right corner. \n    After launching, in the Proxy section, you can change the choice of the server you are connected to. \n    connect and choose a connection for the available services at your discretion!\n\nChapter  \"PROXY\" 🛡️ Via VPN is the main tab.\n   Example:\nLet's say you need Discord to always work through Germany.\n• Click on the 💬 Discord group.\n• Select 🇩🇪 Germany from the drop-down list.\n\nReady! Now all other traffic will go through the server selected in 🛡️ Via VPN,\n and Discord — strictly through Germany.",
            "ru": "6. Выберите добавленный профиль в разделе Профили. \n    В Панели управления нажмите кнопку включить в правом нижнем углу. \n    После запуска в разделе Прокси вы можете изменить выбор сервера к которому вас \n    подключить и выбрать подключение для доступных сервисов на свое усмотрение!\n\nРаздел  \"ПРОКСИ\" 🛡️ Через VPN - основная вкладка.\n   Пример:\nПредположим, вам нужно, чтобы именно Discord всегда работал через Германию.\n• Нажмите на группу 💬 Discord.\n• В раскрывшемся списке выберите 🇩🇪 Германия.\n\nГотово! Теперь весь остальной трафик будет идти через сервер выбранный в 🛡️ Через VPN,\n а Discord — строго через Германию."
          }
        }
      }
    ],
    "androidTV": [
      {
        "id": "flclash",
        "name": "FlClashX",
        "isFeatured": true,
        "urlScheme": "flclash://install-config?url=",
        "installationStep": {
          "buttons": [
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-android-arm64-v8a.apk",
              "buttonText": {
                "en": "Download APK (arm64-v8a)",
                "ru": "Скачать APK (arm64-v8a)"
              }
            },
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-android-armeabi-v7a.apk",
              "buttonText": {
                "en": "Download APK (armeabi-v7a)",
                "ru": "Скачать APK (armeabi-v7a)"
              }
            },
            {
              "buttonLink": "https://github.com/pluralplay/FlClashX/releases/download/v0.2.1/FlClashX-0.2.1-android-x86_64.apk",
              "buttonText": {
                "en": "Download APK (x86_64)",
                "ru": "Скачать APK (x86_64)"
              }
            }
          ],
          "description": {
            "en": "Download and install FlClash APK on your TV. Most modern TVs use ARMv8 (64-bit). If installation fails, try ARMv7 (32-bit). x86_64 is for TVs or boxes with Intel or AMD processors (rare).",
            "ru": "1. Скачайте и установите FlClash APK на ваш телевизор. \n  Большинство современных телевизоров используют Arm64-v8a. \n  Если установка не удалась, попробуйте Armeabi-v7a или x86_64\n\n"
          }
        },
        "additionalBeforeAddSubscriptionStep": {
          "buttons": [],
          "description": {
            "en": "2. In the TV application, click Add Profile \n    In the Profiles section, select Add from phone. \n3. On your phone, in the Profiles section, tap the three-dot button and select Send to TV.",
            "ru": "2. В приложении на телевизоре нажмите кнопку Добавить профиль \n    в разделе Профили, выберите пункт Добавить с телефона. \n3. На телефоне в разделе Профили нажмите кнопку с тремя точками и выберите пункт Отправить на ТВ."
          },
          "title": {
            "en": "How to add a subscription on TV",
            "ru": "Как добавить подписку на телевизоре"
          }
        },
        "addSubscriptionStep": {
          "description": {
            "en": "5. Click the button below to add subscription, if you opened the subscription page on your TV",
            "ru": "5. Нажмите кнопку ниже, чтобы добавить подписку, если вы открыли страницу подписки на телевизоре"
          }
        },
        "additionalAfterAddSubscriptionStep": {
          "buttons": [],
          "title": {
            "en": "If the subscription is not added",
            "ru": "Если подписка не добавилась"
          },
          "description": {
            "en": "6. If nothing happens after clicking on the button, add the subscription manually. \n    On this page, click the Get Link button in the upper-right corner and copy the link. \n    Paste it into any text editor or into any window where you can type text.\n    You will see your individual link.\n    In FlClash, go to the Profiles section, click the + button, select the URL, enter the link and click Send",
            "ru": "6. Если после нажатия на кнопку ничего не произошло, добавьте подписку вручную. \n    Нажмите на этой странице кнопку Получить ссылку в правом верхнем углу, скопируйте ссылку. \n    Вставьте в любой текстовый редактор или в любое окно где можно набирать текст.\n    Вы увидите вашу индивидуальную ссылку.\n    В FlClash перейдите в раздел Профили, нажмите кнопку +, выберите URL, пропишите ссылку и нажмите Отправить"
          }
        },
        "connectAndUseStep": {
          "description": {
            "en": "6. Select the added profile in the Profiles section. \n    In the Control Panel, click the enable button in the lower-right corner. \n    After launching, in the Proxy section, you can change the choice of the server you are connected to. \n    connect and choose a connection for the available services at your discretion!\n\nChapter  \"PROXY\" 🛡️ Via VPN is the main tab.\n   Example:\nLet's say you need Discord to always work through Germany.\n• Click on the 💬 Discord group.\n• Select 🇩🇪 Germany from the drop-down list.\n\nReady! Now all other traffic will go through the server selected in 🛡️ Via VPN,\n and Discord — strictly through Germany.",
            "ru": "Выберите добавленный профиль в разделе Профили. В Панели управления нажмите кнопку включить в правом нижнем углу. После запуска в разделе Прокси вы можете изменить выбор сервера6. Выберите добавленный профиль в разделе Профили. \n    В Панели управления нажмите кнопку включить в правом нижнем углу. \n    После запуска в разделе Прокси вы можете изменить выбор сервера к которому вас \n    подключить и выбрать подключение для доступных сервисов на свое усмотрение!\n\nРаздел  \"ПРОКСИ\" 🛡️ Через VPN - основная вкладка.\n   Пример:\nПредположим, вам нужно, чтобы именно Discord всегда работал через Германию.\n• Нажмите на группу 💬 Discord.\n• В раскрывшемся списке выберите 🇩🇪 Германия.\n\nГотово! Теперь весь остальной трафик будет идти через сервер выбранный в 🛡️ Через VPN,\n а Discord — строго через Германию. к которому вас подключит. "
          }
        }
      }
    ],
    "appleTV": []
  }
}
EOF

    # 5. Получение SSL
    log "🔒 Получаю SSL сертификаты (Certbot)..."
    DOMAINS="-d auth.$MAIN_DOMAIN -d panrem.$MAIN_DOMAIN -d subrem.$MAIN_DOMAIN -d hooks.$MAIN_DOMAIN -d miniapp.$MAIN_DOMAIN -d apibot.$MAIN_DOMAIN -d subapp.$MAIN_DOMAIN"
    
    if certbot certonly --nginx --non-interactive --agree-tos -m admin@$MAIN_DOMAIN $DOMAINS; then
        log "✅ Сертификаты получены!"
    else
        log "⚠️ Ошибка Certbot через Nginx. Пробую Standalone..."
        systemctl stop nginx
        certbot certonly --standalone --non-interactive --agree-tos -m admin@$MAIN_DOMAIN $DOMAINS
        systemctl start nginx
    fi

    # 6. Настройка Nginx
    log "⚙️ Настраиваю Nginx..."
    if [ -f "$NGINX_CONF_DIR/nginx.conf" ]; then
        mv "$NGINX_CONF_DIR/nginx.conf" "$NGINX_CONF_DIR/nginx.conf.bak.$(date +%s)"
    fi

    cat <<EOF > "$NGINX_CONF_DIR/nginx.conf"
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 4096; }

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 90s;
    client_max_body_size 32M;
    server_names_hash_bucket_size 128;
    server_tokens off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    
    upstream remnawave_panel_api { server 127.0.0.1:3000; }
    upstream remnawave_subscription_page { server 127.0.0.1:3010; }
    upstream remnawave_mini_app { server 127.0.0.1:3020; }
    upstream tinyauth_service { server 127.0.0.1:3002; }
    upstream remnawave_bot_unified { server 127.0.0.1:8080; }

    server {
        listen 80;
        server_name *.$MAIN_DOMAIN;
        return 301 https://\$host\$request_uri;
    }

    # TinyAuth
    server {
        listen 443 ssl;
        http2 on;
        server_name auth.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        location / {
            proxy_pass http://tinyauth_service;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }

    # Panel
    server {
        listen 443 ssl;
        http2 on;
        server_name panrem.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        
        location / {
            auth_request /auth_verify;
            error_page 401 = @auth_login;
            proxy_pass http://remnawave_panel_api;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
        location = /auth_verify {
            internal;
            proxy_pass http://tinyauth_service/api/auth/nginx;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header X-Original-URI \$request_uri;
        }
        location @auth_login {
            internal;
            return 302 https://auth.$MAIN_DOMAIN/login?redirect_uri=https://\$host\$request_uri;
        }
    }

    # Sub Page
    server {
        listen 443 ssl;
        http2 on;
        server_name subrem.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        location / {
            proxy_pass http://remnawave_subscription_page;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    # Hooks
    server {
        listen 443 ssl;
        http2 on;
        server_name hooks.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        location / {
            proxy_pass http://remnawave_bot_unified;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    # Mini App
    server {
        listen 443 ssl;
        http2 on;
        server_name miniapp.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        add_header X-Frame-Options "";
        root $MINIAPP_DIR;
        index index.html;
        location /miniapp/ {
            proxy_pass http://remnawave_bot_unified/miniapp/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
        location / { try_files \$uri \$uri/ /index.html; }
    }

    # API Bot
    server {
        listen 443 ssl;
        http2 on;
        server_name apibot.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        location / {
            proxy_pass http://remnawave_bot_unified;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }

    # Sub App (Redirect)
    server {
        listen 443 ssl;
        http2 on;
        server_name subapp.$MAIN_DOMAIN;
        ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
        add_header X-Frame-Options "";
        
        location /myredirect/ {
            alias $MINIAPP_DIR/myredirect/;
            try_files \$uri \$uri/ /index.html;
        }
        location / {
            proxy_pass http://remnawave_mini_app;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF

    log "🔄 Перезагружаю Nginx..."
    run_cmd nginx -t && run_cmd systemctl reload nginx

    # 7. Запуск Docker
    log "🚀 Запускаю контейнеры..."
    cd "$INSTALL_DIR"
    run_cmd docker compose up -d

    echo ""
    echo -e "${C_GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА!${C_RESET}"
    echo -e "Панель: https://panrem.$MAIN_DOMAIN"
    echo -e "TinyAuth Логин: $TA_USER"
    echo -e "TinyAuth Пароль: (твой пароль)"
    echo -e "Подписка: https://subrem.$MAIN_DOMAIN"
    echo -e "Мини-апп: https://subapp.$MAIN_DOMAIN"
    
    read -p "Нажми Enter, чтобы вернуться..."
}

main_install