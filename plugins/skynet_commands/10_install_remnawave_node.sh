#!/bin/bash
# TITLE: Установить ноду Remnawave на выбранный сервер (через Skynet)
# SKYNET_HIDDEN: true
# ============================================================ #
# ==   SKYNET ПЛАГИН: УСТАНОВКА REMNAWAVE НОДЫ НА СЕРВЕР    == #
# ============================================================ #
#
# ВАЖНО: этот скрипт выполняется НА УДАЛЁННОМ СЕРВЕРЕ через Skynet.
# Он НЕ должен спрашивать пользователя ни о чём (никаких read).
# Все параметры прилетают через переменные окружения.
#
# Ожидаемые переменные окружения:
#   SELFSTEAL_DOMAIN  — домен ноды (обязателен)
#   NODE_PORT         — порт ноды (опционально, по умолчанию 2222)
#   NODE_SECRET_KEY   — публичный x25519 ключ (SECRET_KEY) от панели; если не задан, ставится плейсхолдер в docker-compose.yml
#   CERT_MODE         — режим TLS для ноды: "" = только HTTP; "node_acme" = сразу выписать Let's Encrypt (ACME HTTP-01) на selfsteal-домен
#   LETSENCRYPT_EMAIL — (опционально) e-mail для регистрации в certbot; если не задан, используется --register-unsafely-without-email
#
set -euo pipefail

log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

ensure_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "Нужен root. Запускай плагин от рута на удалённом сервере."
        exit 1
    fi
}

ensure_cmd() {
    local bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1; then
        log_error "Нужна утилита '$bin', но её нет в PATH. Установи и повтори."
        exit 1
    fi
}

write_runtime_files() {
    local domain="$1"
    local node_port="$2"
    local secret_key="$3"

    mkdir -p /opt/remnanode || {
        log_error "Не смог создать /opt/remnanode"
        exit 1
    }

    cat > /opt/remnanode/docker-compose.yml <<EOL
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=${node_port}
      - SECRET_KEY="${secret_key}"
    volumes:
      - /dev/shm:/dev/shm:rw
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnanode-nginx:
    image: nginx:1.28
    container_name: remnanode-nginx
    hostname: remnanode-nginx
    network_mode: host
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /var/www/html:/var/www/html:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'
EOL

    cat > /opt/remnanode/nginx.conf <<EOL
server {
    listen 80;
    server_name ${domain};

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}
EOL

    if [[ ! -f /var/www/html/index.html ]]; then
        mkdir -p /var/www/html
        cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Welcome</title>
  <style>
    body { font-family: system-ui, sans-serif; background:#050816; color:#f5f5f5; display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }
    .card { padding:32px 40px; background:rgba(15,23,42,0.9); border-radius:16px; box-shadow:0 18px 45px rgba(0,0,0,0.6); max-width:520px; text-align:center; }
    h1 { font-size:26px; margin-bottom:8px; }
    p { font-size:14px; opacity:0.9; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Service is running</h1>
    <p>Static content placeholder. Nothing to see here.</p>
  </div>
</body>
</html>
HTML
    fi
}

start_containers() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker не установлен на удалённом сервере."
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Не найден плагин 'docker compose'. Обнови Docker / docker-compose."
        exit 1
    fi

    ( cd /opt/remnanode && docker compose up -d ) || {
        log_error "docker compose up -d для удалённой ноды отработал с ошибкой."
        exit 1
    }
}

install_remask_tool_remote() {
    mkdir -p /opt/remnanode/tools || {
        log_warn "Не смог создать /opt/remnanode/tools для remask.sh"
        return 1
    }

    cat > /opt/remnanode/tools/remask.sh <<'EOF'
#!/bin/bash
# remask.sh (remote) — рандомная маскировка для selfsteal-домена ноды
set -euo pipefail

log() {
    echo "[remask] $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"
}

for bin in wget unzip; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        log "нужна утилита '$bin' (apt install $bin). Выходим."
        exit 1
    fi
done

WORKDIR="$(mktemp -d /opt/remnanode/remask.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

TEMPLATES=(
  "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
  "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
  "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
)

SOURCE=${REMASK_SOURCE:-}
case "$SOURCE" in
  simple) IDX=0 ;;
  sni)    IDX=1 ;;
  nothing)IDX=2 ;;
  *)      IDX=$((RANDOM % 3)) ;;
esac

URL="${TEMPLATES[$IDX]}"
log "качаю шаблоны: $URL"

if ! wget -q -O main.zip --timeout=60 --tries=5 --retry-connrefused "$URL"; then
    log "не смог скачать архив шаблонов"
    exit 1
fi

unzip -q main.zip || { log "ошибка распаковки архива"; exit 1 }

SRCDIR=""
case "$URL" in
  *simple-web-templates*) SRCDIR="$WORKDIR/simple-web-templates-main" ;;
  *nothing-sni*)          SRCDIR="$WORKDIR/nothing-sni-main" ;;
  *)                      SRCDIR="$WORKDIR/sni-templates-main" ;;
esac

if [[ ! -d "$SRCDIR" ]]; then
    log "не нашёл распакованный каталог шаблонов ($SRCDIR)"
    exit 1
fi

mkdir -p /var/www/html

if [[ "$URL" == *"nothing-sni"* ]]; then
    mapfile -t HTMLS < <(find "$SRCDIR" -maxdepth 1 -type f -name '*.html')
    if [[ ${#HTMLS[@]} -eq 0 ]]; then
        log "в nothing-sni не нашёл ни одного .html файла"
        exit 1
    fi
    PICKED="${HTMLS[$((RANDOM % ${#HTMLS[@]}))]}"
    log "выбран шаблон: $PICKED"
    rm -rf /var/www/html/*
    cp "$PICKED" /var/www/html/index.html
else
    mapfile -t DIRS < <(find "$SRCDIR" -maxdepth 1 -mindepth 1 -type d)
    if [[ ${#DIRS[@]} -eq 0 ]]; then
        log "в $SRCDIR нет подпапок с шаблонами"
        exit 1
    fi
    PICKED="${DIRS[$((RANDOM % ${#DIRS[@]}))]}"
    log "выбран шаблон: $PICKED"
    rm -rf /var/www/html/*
    cp -r "$PICKED"/. /var/www/html/
fi

log "маскировочный сайт обновлён в /var/www/html"
EOF

    chmod +x /opt/remnanode/tools/remask.sh || return 1

    # cron: раз в 14 дней в 03:17 по серверному времени
    if ! crontab -u root -l 2>/dev/null | grep -q '/opt/remnanode/tools/remask.sh'; then
        local current
        current=$(crontab -u root -l 2>/dev/null || true)
        printf '%s\n%s\n' "$current" "17 3 */14 * * /opt/remnanode/tools/remask.sh >/var/log/remnanode_remask.log 2>&1" | crontab -u root - || {
            log "не получилось прописать cron для remask.sh. Проверь crontab вручную."
        }
    fi
}

# TLS (ACME HTTP-01) для удалённой ноды (упрощённый вариант)
write_nginx_tls_remote() {
    local selfsteal_domain="$1"

    cat > /opt/remnanode/nginx.conf <<EOL
server {
    listen 80;
    server_name $selfsteal_domain;

    return 301 https://$selfsteal_domain\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $selfsteal_domain;

    ssl_certificate     /etc/letsencrypt/live/$selfsteal_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$selfsteal_domain/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}
EOL
}

setup_tls_renew_remote() {
    local selfsteal_domain="$1"
    local renewal_conf="/etc/letsencrypt/renewal/$selfsteal_domain.conf"

    if [[ ! -f "$renewal_conf" ]]; then
        log "не нашёл $renewal_conf — renew_hook для удалённой ноды не настроен."
        return 1
    fi

    local hook
    hook="renew_hook = sh -c 'cd /opt/remnanode && docker compose down remnanode-nginx && docker compose up -d remnanode-nginx'"

    if grep -q '^renew_hook' "$renewal_conf"; then
        sed -i "s|^renew_hook.*|$hook|" "$renewal_conf" || return 1
    else
        echo "$hook" >> "$renewal_conf" || return 1
    fi

    # cron на certbot renew раз в день в 05:00, если ещё нет никакого
    if ! crontab -u root -l 2>/dev/null | grep -q '/usr/bin/certbot renew'; then
        local current
        current=$(crontab -u root -l 2>/dev/null || true)
        printf '%s\n%s\n' "$current" "0 5 * * * /usr/bin/certbot renew --quiet" | crontab -u root - || {
            log "не получилось прописать cron для certbot renew на удалённой ноде."
        }
    fi

    return 0
}

setup_tls_acme_remote() {
    local selfsteal_domain="$1"

    if ! command -v certbot >/dev/null 2>&1; then
        log "certbot не установлен на удалённом сервере, TLS для ноды пропускаем."
        return 1
    fi

    local email
    email="${LETSENCRYPT_EMAIL:-}"

    local -a certbot_args
    certbot_args=(certbot certonly --standalone -d "$selfsteal_domain" --agree-tos --non-interactive --http-01-port 80 --key-type ecdsa --elliptic-curve secp384r1)
    if [[ -n "$email" ]]; then
        certbot_args+=(--email "$email")
    else
        certbot_args+=(--register-unsafely-without-email)
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp comment 'reshala remnanode acme http-01' >/dev/null 2>&1 || true
    fi

    if ! "${certbot_args[@]}"; then
        log "certbot не смог выписать сертификат для $selfsteal_domain."
        if command -v ufw >/dev/null 2>&1; then
            ufw delete allow 80/tcp >/dev/null 2>&1 || true
            ufw reload >/dev/null 2>&1 || true
        fi
        return 1
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow 80/tcp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    fi

    if [[ ! -d "/etc/letsencrypt/live/$selfsteal_domain" ]]; then
        log "Каталог /etc/letsencrypt/live/$selfsteal_domain не появился после certbot. TLS пропускаем."
        return 1
    fi

    write_nginx_tls_remote "$selfsteal_domain" || return 1
    setup_tls_renew_remote "$selfsteal_domain" || true

    log "TLS для удалённой ноды настроен. nginx будет слушать 443 с сертификатом Let's Encrypt."
    return 0
}

main() {
    ensure_root

    if [[ -z "${SELFSTEAL_DOMAIN:-}" ]]; then
        log_error "SELFSTEAL_DOMAIN не задан. Плагин должен вызываться только из Решалы/Skynet с нужным окружением."
        exit 1
    fi
    local node_port secret_key
    node_port="${NODE_PORT:-2222}"
    # Если ключ не передан, используем тот же плейсхолдер, что и в локальном шаблоне ноды
    secret_key="${NODE_SECRET_KEY:-PUBLIC KEY FROM REMNAWAVE-PANEL}"

    log_info "Готовлю /opt/remnanode на удалённом сервере для домена ${SELFSTEAL_DOMAIN} (HTTP-режим)..."
    write_runtime_files "$SELFSTEAL_DOMAIN" "$node_port" "$secret_key"

    if [[ "${CERT_MODE:-}" == "node_acme" ]]; then
        log_info "Пробую сразу выписать HTTPS/TLS-сертификат Let's Encrypt (ACME HTTP-01) для ${SELFSTEAL_DOMAIN} (шифрует трафик и даёт нормальный https-замочек)."
        if ! setup_tls_acme_remote "$SELFSTEAL_DOMAIN"; then
            log_warn "TLS для удалённой ноды получить не удалось, остаёмся на HTTP."
        fi
    fi

    log_info "Ставлю remask.sh на удалённой ноде (автосмена морды раз в ~14 дней)..."
    install_remask_tool_remote || log_warn "remask.sh на удалённой ноде накатить не удалось, маскировку придётся обновлять руками."

    log_info "Стартую контейнеры remnanode и remnanode-nginx через docker compose..."
    start_containers

    if [[ "${CERT_MODE:-}" == "node_acme" ]]; then
        log_info "Удалённая нода Remnawave поднята (HTTPS-маскировка на https://${SELFSTEAL_DOMAIN}, порт ноды ${node_port})."
    else
        log_info "Удалённая нода Remnawave поднята (HTTP-маскировка на http://${SELFSTEAL_DOMAIN}, порт ноды ${node_port})."
    fi
}

main "$@"
