#!/bin/bash
# ============================================================ #
# ==             МОДУЛЬ REMNAWAVE: НОДЫ И SKYNET             == #
# ============================================================ #
#
# Управляет установкой нод Remnawave:
#  - локально на этот сервер;
#  - удалённо через Skynet (одна или несколько нод).
# Использует HTTP API панели и Skynet-плагины.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# === ВНУТРЕННИЕ ХЕЛПЕРЫ (будут заполняться по плану) =========

# Проверка, что домен резолвится и указывает на этот сервер (по мотивам donor check_domain)
_remna_node_check_domain() {
    local domain="$1"
    local show_warning="${2:-true}"
    local allow_cf_proxy="${3:-true}"

    local domain_ip=""
    local server_ip=""

    if command -v dig >/dev/null 2>&1; then
        domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    else
        domain_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')
    fi

    server_ip=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || curl -s -4 ipinfo.io/ip)

    # 0  - всё ок
    # 1  - есть проблема, но пользователь согласился продолжить
    # 2  - пользователь решил прервать установку

    if [[ -z "$domain_ip" || -z "$server_ip" ]]; then
        if [[ "$show_warning" == true ]]; then
            warn "Не смог определить IP домена '$domain' или IP этого сервера."
            info "Проверь DNS: домен должен указывать на текущий сервер. Сейчас сервер видится как: ${server_ip:-\"не удалось определить\"}."
            local confirm
            confirm=$(safe_read "Продолжить установку, игнорируя эту проверку? (y/N): " "n")
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                return 2
            fi
        fi
        return 1
    fi

    local cf_ranges
    local -a cf_array=()
    cf_ranges=$(curl -s https://www.cloudflare.com/ips-v4 || true)
    if [[ -n "$cf_ranges" ]]; then
        mapfile -t cf_array <<<"$cf_ranges"
    fi

    local ip_in_cloudflare=false
    local a b c d
    local domain_ip_int
    local IFS='.'
    read -r a b c d <<<"$domain_ip"
    domain_ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))

    if (( ${#cf_array[@]} > 0 )); then
        local cidr network mask network_int mask_bits range_size min_ip_int max_ip_int
        for cidr in "${cf_array[@]}"; do
            [[ -z "$cidr" ]] && continue
            network=${cidr%/*}
            mask=${cidr#*/}
            IFS='.' read -r a b c d <<<"$network"
            network_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
            mask_bits=$(( 32 - mask ))
            range_size=$(( 1 << mask_bits ))
            min_ip_int=$network_int
            max_ip_int=$(( network_int + range_size - 1 ))

            if (( domain_ip_int >= min_ip_int && domain_ip_int <= max_ip_int )); then
                ip_in_cloudflare=true
                break
            fi
        done
    fi

    if [[ "$domain_ip" == "$server_ip" ]]; then
        return 0
    elif [[ "$ip_in_cloudflare" == true ]]; then
        if [[ "$allow_cf_proxy" == true ]]; then
            return 0
        fi

        if [[ "$show_warning" == true ]]; then
            warn "Домен '$domain' сейчас указывает на IP Cloudflare ($domain_ip), для selfsteal-домена так нельзя."
            info "Выключи оранжевое облако (режим 'DNS only') для этого домена в Cloudflare, подожди обновление DNS и запусти установку ещё раз."
            local confirm
            confirm=$(safe_read "Всё равно продолжить установку? (y/N): " "n")
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                return 1
            else
                return 2
            fi
        fi
        return 1
    else
        if [[ "$show_warning" == true ]]; then
            warn "Домен '$domain' указывает на IP $domain_ip, а текущий сервер видится как $server_ip."
            info "Для нормальной работы ноды Remnawave домен должен указывать именно на этот сервер."
            local confirm
            confirm=$(safe_read "Продолжить установку, игнорируя несовпадение IP? (y/N): " "n")
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                return 1
            else
                return 2
            fi
        fi
        return 1
    fi

    return 0
}

# --- HTTP API хелперы для работы с панелью ---------------------

_remna_node_api_request() {
    local method="$1"
    local url="$2"
    local token="${3:-}"
    local data="${4:-}"

    local args=(-s -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "X-Remnawave-Client-Type: reshala-node")

    if [[ -n "$token" ]]; then
        args+=( -H "Authorization: Bearer $token" )
    fi
    if [[ -n "$data" ]]; then
        args+=( -d "$data" )
    fi

    curl "${args[@]}"
}

_remna_node_api_generate_x25519() {
    local domain_url="$1"
    local token="$2"

    local resp
    resp=$(_remna_node_api_request "GET" "http://$domain_url/api/system/tools/x25519/generate" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Панель не ответила на генерацию x25519-ключей (нодовый модуль)."
        return 1
    fi

    local priv
    priv=$(echo "$resp" | jq -r '.response.keypairs[0].privateKey // empty') || true
    if [[ -z "$priv" || "$priv" == "null" ]]; then
        err "Не смог вытащить privateKey из ответа x25519 (нодовый модуль)."
        log "node x25519 response: $resp"
        return 1
    fi

    echo "$priv"
}

_remna_node_api_create_config_profile() {
    local domain_url="$1"
    local token="$2"
    local name="$3"
    local domain="$4"
    local private_key="$5"
    local inbound_tag="${6:-Steal}"

    local short_id
    short_id=$(openssl rand -hex 8 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 16)

    local body
    body=$(jq -n \
        --arg name "$name" \
        --arg domain "$domain" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --arg inbound_tag "$inbound_tag" '{
            name: $name,
            config: {
                log: { loglevel: "warning" },
                dns: {
                    queryStrategy: "UseIPv4",
                    servers: [{ address: "https://dns.google/dns-query", skipFallback: false }]
                },
                inbounds: [{
                    tag: $inbound_tag,
                    port: 443,
                    protocol: "vless",
                    settings: { clients: [], decryption: "none" },
                    sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
                    streamSettings: {
                        network: "tcp",
                        security: "reality",
                        realitySettings: {
                            show: false,
                            xver: 1,
                            dest: "/dev/shm/nginx.sock",
                            spiderX: "",
                            shortIds: [$short_id],
                            privateKey: $private_key,
                            serverNames: [$domain]
                        }
                    }
                }],
                outbounds: [
                    { tag: "DIRECT", protocol: "freedom" },
                    { tag: "BLOCK", protocol: "blackhole" }
                ],
                routing: {
                    rules: [
                        { ip: ["geoip:private"], type: "field", outboundTag: "BLOCK" },
                        { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" }
                    ]
                }
            }
        }') || return 1

    local resp
    resp=$(_remna_node_api_request "POST" "http://$domain_url/api/config-profiles" "$token" "$body") || true
    if [[ -z "$resp" ]]; then
        err "Не получил ответ от /api/config-profiles при создании профиля для ноды."
        return 1
    fi

    local cfg inbound
    cfg=$(echo "$resp" | jq -r '.response.uuid // empty') || true
    inbound=$(echo "$resp" | jq -r '.response.inbounds[0].uuid // empty') || true

    if [[ -z "$cfg" || -z "$inbound" || "$cfg" == "null" || "$inbound" == "null" ]]; then
        err "API вернуло кривые UUID для config profile/inbound (нодовый модуль)."
        log "node create_config_profile response: $resp"
        return 1
    fi

    echo "$cfg $inbound"
}

_remna_node_api_create_node() {
    local domain_url="$1"
    local token="$2"
    local config_profile_uuid="$3"
    local inbound_uuid="$4"
    local node_address="${5:-172.30.0.1}"
    local node_name="${6:-Steal}"

    local body
    body=$(jq -n \
        --arg cfg "$config_profile_uuid" \
        --arg inb "$inbound_uuid" \
        --arg addr "$node_address" \
        --arg name "$node_name" '{
            name: $name,
            address: $addr,
            port: 2222,
            configProfile: {
                activeConfigProfileUuid: $cfg,
                activeInbounds: [$inb]
            },
            isTrafficTrackingActive: false,
            trafficLimitBytes: 0,
            notifyPercent: 0,
            trafficResetDay: 31,
            excludedInbounds: [],
            countryCode: "XX",
            consumptionMultiplier: 1.0
        }') || return 1

    local resp
    resp=$(_remna_node_api_request "POST" "http://$domain_url/api/nodes" "$token" "$body") || true
    if [[ -z "$resp" ]]; then
        err "Пустой ответ от /api/nodes при создании ноды."
        return 1
    fi

    if ! echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err "Не удалось создать ноду в панели (нет response.uuid)."
        log "node create_node response: $resp"
        return 1
    fi

    return 0
}

_remna_node_api_create_host() {
    local domain_url="$1"
    local token="$2"
    local inbound_uuid="$3"
    local address="$4"
    local config_uuid="$5"
    local remark="${6:-Steal}"

    local body
    body=$(jq -n \
        --arg cfg "$config_uuid" \
        --arg inb "$inbound_uuid" \
        --arg addr "$address" \
        --arg r "$remark" '{
            inbound: {
                configProfileUuid: $cfg,
                configProfileInboundUuid: $inb
            },
            remark: $r,
            address: $addr,
            port: 443,
            path: "",
            sni: $addr,
            host: "",
            alpn: null,
            fingerprint: "chrome",
            allowInsecure: false,
            isDisabled: false,
            securityLayer: "DEFAULT"
        }') || return 1

    local resp
    resp=$(_remna_node_api_request "POST" "http://$domain_url/api/hosts" "$token" "$body") || true
    if [[ -z "$resp" ]]; then
        err "Пустой ответ от /api/hosts при создании host'а."
        return 1
    fi

    if ! echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err "Не удалось создать host в панели (нет response.uuid)."
        log "node create_host response: $resp"
        return 1
    fi

    return 0
}

# Проверка, что в панели ещё нет ноды с таким доменом
_remna_node_api_check_node_domain() {
    local domain_url="$1"
    local token="$2"
    local domain="$3"

    local resp
    resp=$(_remna_node_api_request "GET" "http://$domain_url/api/nodes" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Не удалось проверить домен ноды через /api/nodes (пустой ответ)."
        return 1
    fi

    if echo "$resp" | jq -e '.response' >/dev/null 2>&1; then
        local existing
        existing=$(echo "$resp" | jq -r --arg addr "$domain" '.response[] | select(.address == $addr) | .address' 2>/dev/null || true)
        if [[ -n "$existing" ]]; then
            err "В панели уже есть нода с адресом $domain. Возьми другой домен."
            return 1
        fi
        return 0
    else
        local msg
        msg=$(echo "$resp" | jq -r '.message // "Unknown error"' 2>/dev/null || true)
        err "Ошибка при проверке домена ноды через API: $msg"
        log "node check_node_domain response: $resp"
        return 1
    fi
}

# Получение публичного ключа для ноды из панели и прошивка его в docker-compose
_remna_node_api_apply_public_key() {
    local domain_url="$1"
    local token="$2"
    local compose_path="$3"

    local resp
    resp=$(_remna_node_api_request "GET" "http://$domain_url/api/keygen" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Панель не ответила на /api/keygen (нода не получила публичный ключ)."
        return 1
    fi

    local pubkey
    pubkey=$(echo "$resp" | jq -r '.response.pubKey // empty') || true
    if [[ -z "$pubkey" || "$pubkey" == "null" ]]; then
        err "Не смог вытащить pubKey из ответа /api/keygen для ноды."
        log "node keygen response: $resp"
        return 1
    fi

    # Подменяем плейсхолдер SECRET_KEY в docker-compose ноды
    run_cmd sed -i "s|SECRET_KEY=\"PUBLIC KEY FROM REMNAWAVE-PANEL\"|SECRET_KEY=\"$pubkey\"|g" "$compose_path" || return 1

    return 0
}

# Получение публичного ключа панели для использования на удалённых нодах
_remna_node_api_get_public_key() {
    local domain_url="$1"
    local token="$2"

    local resp
    resp=$(_remna_node_api_request "GET" "http://$domain_url/api/keygen" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Панель не ответила на /api/keygen (не получил pubKey для удалённой ноды)."
        return 1
    fi

    local pubkey
    pubkey=$(echo "$resp" | jq -r '.response.pubKey // empty') || true
    if [[ -z "$pubkey" || "$pubkey" == "null" ]]; then
        err "Не смог вытащить pubKey из ответа /api/keygen (удалённая нода)."
        log "node remote keygen response: $resp"
        return 1
    fi

    echo "$pubkey"
}

# --- ЛОКАЛЬНОЕ ОКРУЖЕНИЕ НОДЫ (docker-compose + nginx, HTTP) ---

_remna_node_prepare_runtime_dir() {
    # Отдельная директория под ноду, чтобы не мешать панели
    run_cmd mkdir -p /opt/remnanode || return 1
    return 0
}

_remna_node_write_runtime_compose_and_nginx() {
    local selfsteal_domain="$1"

    # docker-compose.yml для локальной ноды (HTTP-вариант, без TLS)
    cat > /opt/remnanode/docker-compose.yml <<EOL
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="PUBLIC KEY FROM REMNAWAVE-PANEL"
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

    # nginx.conf: пока только HTTP-маскировка на 80 порту
    cat > /opt/remnanode/nginx.conf <<EOL
server {
    listen 80;
    server_name $selfsteal_domain;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}
EOL

    # Базовый маскировочный сайт, если ещё ничего нет
    if [[ ! -f /var/www/html/index.html ]]; then
        run_cmd mkdir -p /var/www/html || return 1
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

    return 0
}

# --- Маскировка: remask.sh + cron ------------------------------

_remna_node_install_remask_tool() {
    # Скрипт будет жить в /opt/remnanode/tools/remask.sh и крутить рандомные шаблоны в /var/www/html
    run_cmd mkdir -p /opt/remnanode/tools || return 1

    cat > /opt/remnanode/tools/remask.sh <<'EOF'
#!/bin/bash
# ============================================================ #
#  remask.sh — рандомная маскировка для selfsteal-домена ноды  #
# ============================================================ #
# Тянет один из публичных наборов шаблонов (simple/sni/nothing)
# и заливает случайный шаблон в /var/www/html как маскировку.
#
# Запускать от root (или через cron). Никаких интерактивных
# вопросов не задаёт.

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

# Можно передать REMASK_SOURCE=simple|sni|nothing, иначе выберем рандомно
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

unzip -q main.zip || { log "ошибка распаковки архива"; exit 1; }

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
    # В nothing-sni лежит пачка HTML-файлов — просто выбираем один и кладём как index.html
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
    # simple/sni: выбираем случайную подпапку и заливаем её содержимое в /var/www/html
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

    run_cmd chmod +x /opt/remnanode/tools/remask.sh || return 1

    # cron: раз в 14 дней в 03:17 по серверному времени
    if ! crontab -u root -l 2>/dev/null | grep -q '/opt/remnanode/tools/remask.sh'; then
        info "Вешаю cron на периодическую смену маскировочного сайта ноды (раз в ~14 дней)."
        local current
        current=$(crontab -u root -l 2>/dev/null || true)
        printf '%s\n%s\n' "$current" "17 3 */14 * * /opt/remnanode/tools/remask.sh >/var/log/remnanode_remask.log 2>&1" | run_cmd crontab -u root - || {
            warn "Не получилось прописать cron для remask.sh. Проверь crontab вручную."
        }
    fi

    ok "remask.sh установлен в /opt/remnanode/tools и будет периодически обновлять /var/www/html."
    return 0
}

# --- TLS для локальной ноды (упрощённый ACME HTTP-01) ----------

# Переписывает nginx.conf под HTTPS (Let's Encrypt cert в /etc/letsencrypt)
_remna_node_write_nginx_tls() {
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

# Запрос сертификата Let's Encrypt (ACME HTTP-01, certbot --standalone)
_remna_node_setup_tls_acme() {
    local selfsteal_domain="$1"

    info "Готовлю TLS-сертификат Let's Encrypt для selfsteal-домена $selfsteal_domain (ACME HTTP-01)..."

    if ! command -v certbot >/dev/null 2>&1; then
        info "Не вижу certbot, сейчас попробую аккуратно докрутить пакет..."
        if ! ensure_package certbot; then
            err "Не смог установить certbot. TLS для ноды пока пропускаем."
            return 1
        fi
    fi

    local email
    email=$(safe_read "Email для Let's Encrypt (уведомления, можно пустой): " "")

    local -a certbot_args
    certbot_args=(certbot certonly --standalone -d "$selfsteal_domain" --agree-tos --non-interactive --http-01-port 80 --key-type ecdsa --elliptic-curve secp384r1)
    if [[ -n "$email" ]]; then
        certbot_args+=(--email "$email")
    else
        certbot_args+=(--register-unsafely-without-email)
    fi

    # Если есть ufw — временно откроем 80 порт под challenge
    if command -v ufw >/dev/null 2>&1; then
        run_cmd ufw allow 80/tcp comment 'reshala remnanode acme http-01' || true
    fi

    if ! run_cmd "${certbot_args[@]}"; then
        err "certbot не смог выписать сертификат для $selfsteal_domain."
        if command -v ufw >/dev/null 2>&1; then
            run_cmd ufw delete allow 80/tcp || true
            run_cmd ufw reload || true
        fi
        return 1
    fi

    if command -v ufw >/dev/null 2>&1; then
        run_cmd ufw delete allow 80/tcp || true
        run_cmd ufw reload || true
    fi

    if [[ ! -d "/etc/letsencrypt/live/$selfsteal_domain" ]]; then
        err "Каталог /etc/letsencrypt/live/$selfsteal_domain не появился после certbot. TLS пропускаем."
        return 1
    fi

    _remna_node_write_nginx_tls "$selfsteal_domain" || return 1

    # Настраиваем renew_hook и простейший cron для certbot renew
    _remna_node_setup_tls_renew "$selfsteal_domain" || warn "renew_hook/cron для TLS-ноды не удалось настроить автоматически, смотри /etc/letsencrypt/renewal/$selfsteal_domain.conf."

    ok "TLS-конфиг для ноды собран, nginx будет слушать 443 с сертификатом Let's Encrypt."
    return 0
}

# renew_hook + cron для автопродления сертификата selfsteal-домена ноды
_remna_node_setup_tls_renew() {
    local selfsteal_domain="$1"
    local renewal_conf="/etc/letsencrypt/renewal/$selfsteal_domain.conf"

    if [[ ! -f "$renewal_conf" ]]; then
        warn "Не нашёл $renewal_conf — не на что вешать renew_hook для ноды. Пропускаю авто-настройку."
        return 1
    fi

    local hook
    hook="renew_hook = sh -c 'cd /opt/remnanode && docker compose down remnanode-nginx && docker compose up -d remnanode-nginx'"

    if grep -q '^renew_hook' "$renewal_conf"; then
        run_cmd sed -i "s|^renew_hook.*|$hook|" "$renewal_conf" || return 1
    else
        echo "$hook" | run_cmd tee -a "$renewal_conf" >/dev/null || return 1
    fi

    ok "renew_hook для selfsteal-домена ноды прописан в $renewal_conf."

    # Простейший cron на certbot renew раз в день в 05:00, если ещё нет никакого
    if ! crontab -u root -l 2>/dev/null | grep -q '/usr/bin/certbot renew'; then
        info "Вешаю cron-задачу на certbot renew для сертификатов (включая ноду)."
        local current
        current=$(crontab -u root -l 2>/dev/null || true)
        printf '%s
%s
' "$current" "0 5 * * * /usr/bin/certbot renew --quiet" | run_cmd crontab -u root - || {
            warn "Не получилось прописать cron для certbot renew. Проверь crontab вручную."
        }
    else
        info "cron с certbot renew уже есть — не трогаю его."
    fi

    return 0
}

# Получение UUID дефолтного internal-squad из панели (нодовый модуль)
_remna_node_api_get_default_squad_uuid() {
    local domain_url="$1"
    local token="$2"

    local resp
    resp=$(_remna_node_api_request "GET" "http://$domain_url/api/internal-squads" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Пустой ответ от /api/internal-squads (нодовый модуль)."
        return 1
    fi

    local uuid
    uuid=$(echo "$resp" | jq -r '.response.internalSquads[0].uuid // empty') || true
    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        err "Не нашёл ни одного internal squad в панели (нодовый модуль)."
        log "node internal-squads response: $resp"
        return 1
    fi

    echo "$uuid"
}

_remna_node_api_add_inbound_to_squad() {
    local domain_url="$1"
    local token="$2"
    local squad_uuid="$3"
    local inbound_uuid="$4"

    local resp
    resp=$(_remna_node_api_request "GET" "http://$domain_url/api/internal-squads" "$token") || true
    if [[ -z "$resp" ]]; then
        err "Пустой ответ от /api/internal-squads (нодовый модуль)."
        return 1
    fi

    local existing
    existing=$(echo "$resp" | jq -r --arg uuid "$squad_uuid" '.response.internalSquads[] | select(.uuid == $uuid) | .inbounds[].uuid' 2>/dev/null || true)
    if [[ -z "$existing" ]]; then
        existing="[]"
    else
        existing=$(echo "$existing" | jq -R . | jq -s .)
    fi

    local merged
    merged=$(jq -n --argjson ex "$existing" --arg inb "$inbound_uuid" '$ex + [$inb] | unique')

    local body
    body=$(jq -n --arg uuid "$squad_uuid" --argjson inb "$merged" '{uuid:$uuid,inbounds:$inb}')

    local upd
    upd=$(_remna_node_api_request "PATCH" "http://$domain_url/api/internal-squads" "$token" "$body") || true
    if [[ -z "$upd" ]] || ! echo "$upd" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err "Не удалось обновить squad (привязать inbound) в нодовом модуле."
        log "node update_squad response: $upd"
        return 1
    fi

    return 0
}

# Нормализуем ввод API панели: убираем http(s):// и добавляем порт 3000 при необходимости
_remna_node_normalize_panel_api() {
    local api="$1"
    api=${api#http://}
    api=${api#https://}
    if [[ "$api" != *:* ]]; then
        api="$api:3000"
    fi
    echo "$api"
}

# Простая проверка доступности API панели по адресу host:port
# Здесь нас интересует именно Доступность, а не бизнес-логика кода ответа.
_remna_node_check_panel_api() {
    local panel_api_raw="$1"   # может быть с http(s)://
    local panel_api
    panel_api=$(_remna_node_normalize_panel_api "$panel_api_raw")
    local url="http://$panel_api/api/auth/status"

    info "Проверяю доступность API панели по адресу $url..."
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "$url" 2>/dev/null || echo "000")

    if [[ "$http_code" == "000" ]]; then
        err "Не смог подключиться к панели по адресу $panel_api_raw (curl вернул HTTP 000). Проверь DNS/IP, порт и файрвол."
        return 1
    fi

    info "API панели отвечает (HTTP $http_code) — двигаемся дальше."
    echo "$panel_api"
    return 0
}

# Проверка, что API + токен реально работают (используем internal-squads как простую пробу)
_remna_node_check_panel_api_with_token() {
    local panel_api="$1"   # уже host:port
    local token="$2"

    info "Проверяю токен панели через /api/internal-squads..."
    local resp
    resp=$(_remna_node_api_request "GET" "http://$panel_api/api/internal-squads" "$token") || true

    if [[ -z "$resp" ]]; then
        err "Панель вернула пустой ответ на /api/internal-squads. Скорее всего, токен или API введены неверно."
        return 1
    fi

    local any
    any=$(echo "$resp" | jq -r '.response.internalSquads[0].uuid // empty' 2>/dev/null || true)
    if [[ -z "$any" || "$any" == "null" ]]; then
        err "Не удалось получить список internal-squads. Проверь, что токен имеет роль API и введён правильно."
        log "node token check response: $resp"
        return 1
    fi

    ok "Токен панели принят, API отвечает корректно."
    return 0
}

# Быстрая DNS‑проверка selfsteal‑домена (используется в Skynet‑сценариях)
_remna_node_check_domain_dns() {
    local domain="$1"
    local domain_ip=""

    if command -v dig >/dev/null 2>&1; then
        domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n 1)
    else
        domain_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')
    fi

    if [[ -z "$domain_ip" ]]; then
        err "Домен '$domain' не резолвится в IP-адрес. Проверь DNS‑запись перед установкой ноды."
        return 1
    fi

    info "Домен '$domain' резолвится в $domain_ip — DNS выглядит живым."
    return 0
}

# Мастер‑визард установки локальной ноды на этот сервер
_remna_node_install_local_wizard() {
    menu_header "Нода Remnawave на этот сервак"
    echo
    echo "   Ставим НОДУ для уже существующей панели."
    echo "   Панель может быть тут или на другом сервере."
    echo

    local PANEL_API PANEL_API_TOKEN SELFSTEAL_DOMAIN NODE_NAME
    PANEL_API=$(safe_read "API панели (host:port, по умолчанию 127.0.0.1:3000): " "127.0.0.1:3000") || return 130
    local normalized
    normalized=$(_remna_node_check_panel_api "$PANEL_API") || { wait_for_enter; return 1; }
    PANEL_API="$normalized"
    PANEL_API_TOKEN=$(ask_non_empty "API токен панели (создай в разделе API Tokens): " "") || return 130
    if ! _remna_node_check_panel_api_with_token "$PANEL_API" "$PANEL_API_TOKEN"; then
        wait_for_enter
        return 1
    fi
    SELFSTEAL_DOMAIN=$(ask_non_empty "Selfsteal домен ноды (node.example.com): " "") || return 130
    NODE_NAME=$(ask_non_empty "Имя ноды в панели (например Germany-1): " "") || return 130

    if [[ -z "$SELFSTEAL_DOMAIN" || -z "$NODE_NAME" ]]; then
        err "Имя ноды и домен — обязательно."
        return 1
    fi
    if [[ -z "$PANEL_API_TOKEN" ]]; then
        err "Нужен API токен панели, без него я не могу создать ноду через HTTP API."
        return 1
    fi

    info "Проверяю, что selfsteal-домен ноды реально смотрит на этот сервер..."
    local rc
    _remna_node_check_domain "$SELFSTEAL_DOMAIN" true false
    rc=$?
    if [[ $rc -eq 2 ]]; then
        err "Установка ноды прервана по твоему запросу на проверке домена."
        return 1
    fi

    local domain_url="$PANEL_API"

    info "Проверяю, что в панели ещё нет ноды с таким доменом..."
    _remna_node_api_check_node_domain "$domain_url" "$PANEL_API_TOKEN" "$SELFSTEAL_DOMAIN" || return 1

    info "Генерю x25519-ключи для ноды через панель..."
    local private_key
    private_key=$(_remna_node_api_generate_x25519 "$domain_url" "$PANEL_API_TOKEN") || return 1

    info "Создаю config-profile под selfsteal-домен ноды..."
    local cfg inbound
    read -r cfg inbound < <(_remna_node_api_create_config_profile "$domain_url" "$PANEL_API_TOKEN" "Node-$NODE_NAME" "$SELFSTEAL_DOMAIN" "$private_key") || return 1

    info "Регистрирую ноду и host в панели..."
    _remna_node_api_create_node "$domain_url" "$PANEL_API_TOKEN" "$cfg" "$inbound" "$SELFSTEAL_DOMAIN" "$NODE_NAME" || return 1
    _remna_node_api_create_host "$domain_url" "$PANEL_API_TOKEN" "$inbound" "$SELFSTEAL_DOMAIN" "$cfg" "$NODE_NAME" || return 1

    info "Прописываю inbound ноды в дефолтный squad..."
    local squad
    squad=$(_remna_node_api_get_default_squad_uuid "$domain_url" "$PANEL_API_TOKEN") || return 1
    _remna_node_api_add_inbound_to_squad "$domain_url" "$PANEL_API_TOKEN" "$squad" "$inbound" || return 1

    ok "Нода зарегистрирована в панели Remnawave."

    info "Готовлю /opt/remnanode и окружение ноды (HTTP, маскировка)..."
    if ! _remna_node_prepare_runtime_dir; then
        err "Не смог подготовить директорию /opt/remnanode. Смотри логи."
        return 1
    fi

    _remna_node_write_runtime_compose_and_nginx "$SELFSTEAL_DOMAIN" || {
        err "Не смог собрать docker-compose.yml и nginx.conf для ноды."
        return 1
    }

    info "Ставлю remask.sh, чтобы selfsteal-домен ноды сам периодически менял морду."
    _remna_node_install_remask_tool || warn "Не смог накатить remask.sh для ноды, маскировку придётся обновлять руками."

    info "TLS = HTTPS-сертификат для домена: шифрует трафик и даёт нормальный замочек в браузере."
    info "Сейчас могу сразу выписать бесплатный сертификат Let's Encrypt (ACME HTTP-01) для selfsteal-домена."
    local tls_choice
    tls_choice=$(safe_read "Включить HTTPS (TLS-сертификат Let's Encrypt) для этого домена прямо сейчас? (Y/n): " "y")
    if [[ "$tls_choice" == "y" || "$tls_choice" == "Y" ]]; then
        if _remna_node_setup_tls_acme "$SELFSTEAL_DOMAIN"; then
            ok "TLS для ноды получен, nginx сконфигурен на 443."
        else
            warn "TLS для ноды получить не удалось, оставляю HTTP-режим. Можно будет заняться позже вручную."
        fi
    else
        warn "Ок, оставляем пока только HTTP без сертификата. Если что, https://$SELFSTEAL_DOMAIN можно будет докрутить позже."
    fi

    info "Получаю публичный ключ ноды из панели и прошиваю его в SECRET_KEY..."
    _remna_node_api_apply_public_key "$domain_url" "$PANEL_API_TOKEN" "/opt/remnanode/docker-compose.yml" || return 1

    info "Стартую Docker-композ локальной ноды..."
    (
        cd /opt/remnanode && run_cmd docker compose up -d
    ) || {
        err "docker compose up -d для локальной ноды отработал с ошибкой. Смотри docker-логи remnanode/remnanode-nginx."
        return 1
    }

    ok "Локальная нода поднята: маскировочный сайт крутится на http://$SELFSTEAL_DOMAIN, а если TLS завёлся — то и на https://$SELFSTEAL_DOMAIN. SECRET_KEY уже получен из панели."
    wait_for_enter
}

_remna_node_install_skynet_one() {
    clear
    menu_header "Нода Remnawave через Skynet (один сервер)"
    echo
    echo "   Сценарий: панель уже крутится, а ноду хотим воткнуть НА ДРУГОЙ сервак из флота Skynet."
    echo "   На этом сервере я настрою ноду в панели и запущу плагин на выбранном хосте."
    echo

    if [[ ! -f "$FLEET_DATABASE_FILE" || ! -s "$FLEET_DATABASE_FILE" ]]; then
        err "Флот пустой. Сначала зайди в Skynet и добавь хоть один сервер."
        wait_for_enter
        return
    fi

    local PANEL_API PANEL_API_TOKEN SELFSTEAL_DOMAIN NODE_NAME NODE_PORT CERT_MODE
    PANEL_API=$(safe_read "API панели (host:port, по умолчанию 127.0.0.1:3000): " "127.0.0.1:3000") || return
    local normalized
    normalized=$(_remna_node_check_panel_api "$PANEL_API") || { wait_for_enter; return; }
    PANEL_API="$normalized"
    PANEL_API_TOKEN=$(ask_non_empty "API токен панели (создай в разделе API Tokens): " "") || return
    if ! _remna_node_check_panel_api_with_token "$PANEL_API" "$PANEL_API_TOKEN"; then
        wait_for_enter
        return
    fi
    SELFSTEAL_DOMAIN=$(ask_non_empty "Selfsteal домен ноды (node.example.com): " "") || return
    if ! _remna_node_check_domain_dns "$SELFSTEAL_DOMAIN"; then
        wait_for_enter
        return
    fi
    NODE_NAME=$(ask_non_empty "Имя ноды в панели (например Germany-1): " "") || return
    NODE_PORT=$(safe_read "Порт ноды (по умолчанию 2222): " "2222") || return

    local tls_remote_choice
    info "TLS на удалённой ноде = HTTPS-сертификат для selfsteal-домена, шифрует трафик и выглядит как обычный https-сайт."
    tls_remote_choice=$(safe_read "Сделать HTTPS (TLS-сертификат Let's Encrypt) прямо на удалённой ноде? (Y/n): " "y")
    CERT_MODE=""
    if [[ "$tls_remote_choice" == "y" || "$tls_remote_choice" == "Y" ]]; then
        CERT_MODE="node_acme"
    fi

    if [[ -z "$SELFSTEAL_DOMAIN" || -z "$NODE_NAME" ]]; then
        err "Имя ноды и домен — обязательно."
        wait_for_enter
        return
    fi
    if [[ -z "$PANEL_API_TOKEN" ]]; then
        err "Нужен API токен панели, без него я не могу создать ноду через HTTP API."
        wait_for_enter
        return
    fi

    local domain_url="$PANEL_API"

    info "Проверяю, что в панели ещё нет ноды с таким доменом..."
    _remna_node_api_check_node_domain "$domain_url" "$PANEL_API_TOKEN" "$SELFSTEAL_DOMAIN" || { wait_for_enter; return; }

    info "Генерю x25519-ключи для ноды через панель..."
    local private_key
    private_key=$(_remna_node_api_generate_x25519 "$domain_url" "$PANEL_API_TOKEN") || { wait_for_enter; return; }

    info "Создаю config-profile под selfsteal-домен ноды..."
    local cfg inbound
    if ! read -r cfg inbound < <(_remna_node_api_create_config_profile "$domain_url" "$PANEL_API_TOKEN" "Node-$NODE_NAME" "$SELFSTEAL_DOMAIN" "$private_key"); then
        wait_for_enter
        return
    fi

    info "Регистрирую ноду и host в панели..."
    _remna_node_api_create_node "$domain_url" "$PANEL_API_TOKEN" "$cfg" "$inbound" "$SELFSTEAL_DOMAIN" "$NODE_NAME" || { wait_for_enter; return; }
    _remna_node_api_create_host "$domain_url" "$PANEL_API_TOKEN" "$inbound" "$SELFSTEAL_DOMAIN" "$cfg" "$NODE_NAME" || { wait_for_enter; return; }

    info "Прописываю inbound ноды в дефолтный squad..."
    local squad
    squad=$(_remna_node_api_get_default_squad_uuid "$domain_url" "$PANEL_API_TOKEN") || { wait_for_enter; return; }
    _remna_node_api_add_inbound_to_squad "$domain_url" "$PANEL_API_TOKEN" "$squad" "$inbound" || { wait_for_enter; return; }

    ok "Нода зарегистрирована в панели Remnawave (HTTP-конфиг готов). Теперь получим ключ и выберем удалённый сервак из флота."

    info "Получаю публичный ключ ноды из панели (для удалённого сервера)..."
    local pubkey
    pubkey=$(_remna_node_api_get_public_key "$domain_url" "$PANEL_API_TOKEN") || { wait_for_enter; return; }

    # Выбор сервера из флота (упрощённый одноразовый список)
    local servers=()
    local idx=1
    echo
    echo "Доступные сервера Skynet:"
    echo "------------------------------------------------------"
    while IFS='|' read -r name user ip port key_path sudo_pass; do
        [[ -z "$name" ]] && continue
        servers[$idx]="$name|$user|$ip|$port|$key_path|$sudo_pass"
        printf "   [%d] %s (%s@%s:%s)\n" "$idx" "$name" "$user" "$ip" "$port"
        ((idx++))
    done < "$FLEET_DATABASE_FILE"

    if [[ ${#servers[@]} -eq 0 ]]; then
        err "Во флоте нет ни одного сервера."
        wait_for_enter
        return
    fi

    local s_choice
    s_choice=$(ask_number_in_range "Номер сервера для ноды: " 1 "$((idx-1))" "") || { wait_for_enter; return; }
    if [[ -z "${servers[$s_choice]:-}" ]]; then
        err "Нет такого номера сервера."
        wait_for_enter
        return
    fi

    IFS='|' read -r name user ip port key_path sudo_pass <<< "${servers[$s_choice]}"

    info "Запускаю Skynet-плагин установки ноды на сервере '$name'..."

    local plugin_path
    plugin_path="${SCRIPT_DIR}/plugins/skynet_commands/10_install_remnawave_node.sh"
    if [[ ! -f "$plugin_path" ]]; then
        err "Не нашёл плагин $plugin_path. Обнови Решалу или проверь репозиторий."
        wait_for_enter
        return
    fi

    # Собираем строку ENV-переменных для удалённого запуска плагина
    local env_vars
    env_vars="SELFSTEAL_DOMAIN='$SELFSTEAL_DOMAIN' NODE_PORT='$NODE_PORT' NODE_SECRET_KEY='$pubkey' CERT_MODE='$CERT_MODE'"

    _skynet_run_plugin_on_server_with_env "$plugin_path" "$env_vars" "$name" "$user" "$ip" "$port" "$key_path"

    ok "Команда на установку ноды на сервере '$name' отправлена. Проверяй http://$SELFSTEAL_DOMAIN после старта контейнеров."
    wait_for_enter
}

_remna_node_install_skynet_many() {
    clear
    menu_header "Ноды Remnawave через Skynet (несколько серверов)"
    echo
    echo "   Сценарий: панель уже крутится, и хотим раздать НОДЫ сразу на несколько серваков из флота."
    echo "   На этом сервере я настрою ноды в панели и запущу плагин на каждом выбранном хосте."
    echo

    if [[ ! -f "$FLEET_DATABASE_FILE" || ! -s "$FLEET_DATABASE_FILE" ]]; then
        err "Флот пустой. Сначала зайди в Skynet и добавь хоть один сервер."
        wait_for_enter
        return
    fi

    local PANEL_API PANEL_API_TOKEN NODE_PORT CERT_MODE
    PANEL_API=$(safe_read "API панели (host:port, по умолчанию 127.0.0.1:3000): " "127.0.0.1:3000")
    local normalized
    normalized=$(_remna_node_check_panel_api "$PANEL_API") || { wait_for_enter; return; }
    PANEL_API="$normalized"
    PANEL_API_TOKEN=$(safe_read "API токен панели (создай в разделе API Tokens): " "")
    if [[ -z "$PANEL_API_TOKEN" ]]; then
        err "Нужен API токен панели, без него я не могу создавать ноды через HTTP API."
        wait_for_enter
        return
    fi
    if ! _remna_node_check_panel_api_with_token "$PANEL_API" "$PANEL_API_TOKEN"; then
        wait_for_enter
        return
    fi
    NODE_PORT=$(safe_read "Порт нод (по умолчанию 2222, общий для всех): " "2222")

    info "TLS на удалённых нодах = HTTPS-сертификаты для их selfsteal-доменов, шифруют трафик и выглядят как обычные https-сайты."
    local tls_remote_choice
    tls_remote_choice=$(safe_read "Прикрутить HTTPS (TLS Let's Encrypt ACME HTTP-01) на КАЖДОЙ удалённой ноде? (Y/n): " "y")
    CERT_MODE=""
    if [[ "$tls_remote_choice" == "y" || "$tls_remote_choice" == "Y" ]]; then
        CERT_MODE="node_acme"
    fi

    if [[ -z "$PANEL_API_TOKEN" ]]; then
        err "Нужен API токен панели, без него я не могу создавать ноды через HTTP API."
        wait_for_enter
        return
    fi

    local domain_url="$PANEL_API"

    info "Читаю дефолтный squad в панели один раз, чтобы вешать туда все новые ноды."
    local squad
    squad=$(_remna_node_api_get_default_squad_uuid "$domain_url" "$PANEL_API_TOKEN") || { wait_for_enter; return; }

    # Рисуем список серваков из флота
    local servers=()
    local idx=1
    echo
    echo "Доступные сервера Skynet:"
    echo "------------------------------------------------------"
    while IFS='|' read -r name user ip port key_path sudo_pass; do
        [[ -z "$name" ]] && continue
        servers[$idx]="$name|$user|$ip|$port|$key_path|$sudo_pass"
        printf "   [%d] %s (%s@%s:%s)\n" "$idx" "$name" "$user" "$ip" "$port"
        ((idx++))
    done < "$FLEET_DATABASE_FILE"

    if [[ ${#servers[@]} -eq 0 ]]; then
        err "Во флоте нет ни одного сервера."
        wait_for_enter
        return
    fi

    echo
    info "Можно задать несколько номеров через запятую, например: 1,3,5"
    local selection_raw
    selection_raw=$(safe_read "На какие сервера раздать ноды (номера через запятую): " "")
    if [[ -z "$selection_raw" ]]; then
        warn "Ничего не выбрал — массовую установку отменяем."
        wait_for_enter
        return
    fi

    # Нормализуем: убираем пробелы, заменяем запятые на пробел
    local selection_normalized
    selection_normalized=$(echo "$selection_raw" | tr ',' ' ')

    local ok_any=false
    local num
    for num in $selection_normalized; do
        [[ -z "$num" ]] && continue
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [[ -z "${servers[$num]:-}" ]]; then
            warn "Пропускаю некорректный номер сервера: $num"
            continue
        fi

        IFS='|' read -r name user ip port key_path sudo_pass <<< "${servers[$num]}"

        echo
        info "Готовлю ноду для сервера '$name' ($user@$ip:$port)..."

        local SELFSTEAL_DOMAIN NODE_NAME
        SELFSTEAL_DOMAIN=$(safe_read "Selfsteal домен для ноды на сервере '$name' (node.example.com): " "")
        NODE_NAME=$(safe_read "Имя ноды в панели для '$name' (например ${name}-1): " "${name}-1")

        if [[ -z "$SELFSTEAL_DOMAIN" || -z "$NODE_NAME" ]]; then
            warn "Для сервера '$name' домен и имя ноды обязательны, пропускаю."
            continue
        fi

        # Быстрая DNS‑проверка, что домен хотя бы резолвится
        if ! _remna_node_check_domain_dns "$SELFSTEAL_DOMAIN"; then
            warn "DNS для '$SELFSTEAL_DOMAIN' сейчас не годится — этот сервак '$name' пропускаю."
            continue
        fi

        info "Проверяю, что в панели ещё нет ноды с доменом $SELFSTEAL_DOMAIN..."
        if ! _remna_node_api_check_node_domain "$domain_url" "$PANEL_API_TOKEN" "$SELFSTEAL_DOMAIN"; then
            warn "Скрипт панели не дал создать ноду для '$name' (домен занят или ошибка API) — этот сервак пропускаю."
            continue
        fi

        info "Генерю x25519-ключи для ноды '$NODE_NAME' через панель..."
        local private_key
        private_key=$(_remna_node_api_generate_x25519 "$domain_url" "$PANEL_API_TOKEN") || {
            warn "Не смог сгенерировать x25519 для '$name', пропускаю."
            continue
        }

        info "Создаю config-profile под selfsteal-домен $SELFSTEAL_DOMAIN..."
        local cfg inbound
        if ! read -r cfg inbound < <(_remna_node_api_create_config_profile "$domain_url" "$PANEL_API_TOKEN" "Node-$NODE_NAME" "$SELFSTEAL_DOMAIN" "$private_key"); then
            warn "Не смог создать config-profile для '$name', пропускаю."
            continue
        fi

        info "Регистрирую ноду и host в панели для '$name'..."
        if ! _remna_node_api_create_node "$domain_url" "$PANEL_API_TOKEN" "$cfg" "$inbound" "$SELFSTEAL_DOMAIN" "$NODE_NAME"; then
            warn "create_node в панели для '$name' отвалился, пропускаю."
            continue
        fi
        if ! _remna_node_api_create_host "$domain_url" "$PANEL_API_TOKEN" "$inbound" "$SELFSTEAL_DOMAIN" "$cfg" "$NODE_NAME"; then
            warn "create_host в панели для '$name' отвалился, пропускаю."
            continue
        fi

        info "Прописываю inbound ноды '$NODE_NAME' в дефолтный squad..."
        if ! _remna_node_api_add_inbound_to_squad "$domain_url" "$PANEL_API_TOKEN" "$squad" "$inbound"; then
            warn "Не смог привязать inbound к squad для '$name', пропускаю."
            continue
        fi

        info "Тяну публичный ключ ноды из панели (SECRET_KEY) для '$name'..."
        local pubkey
        pubkey=$(_remna_node_api_get_public_key "$domain_url" "$PANEL_API_TOKEN") || {
            warn "Не смог получить pubKey для '$name', пропускаю."
            continue
        }

        local plugin_path
        plugin_path="${SCRIPT_DIR}/plugins/skynet_commands/10_install_remnawave_node.sh"
        if [[ ! -f "$plugin_path" ]]; then
            err "Не нашёл плагин $plugin_path. Обнови Решалу или проверь репозиторий."
            wait_for_enter
            return
        fi

        info "Шлю Skynet-плагин на сервер '$name' (selfsteal-домен $SELFSTEAL_DOMAIN, порт ноды $NODE_PORT)..."
        local env_vars
        env_vars="SELFSTEAL_DOMAIN='$SELFSTEAL_DOMAIN' NODE_PORT='$NODE_PORT' NODE_SECRET_KEY='$pubkey' CERT_MODE='$CERT_MODE'"

        _skynet_run_plugin_on_server_with_env "$plugin_path" "$env_vars" "$name" "$user" "$ip" "$port" "$key_path"
        ok "Команда на установку ноды для '$name' отправлена. После старта контейнеров проверяй http(s)://$SELFSTEAL_DOMAIN."
        ok_any=true
    done

    if [[ "$ok_any" == true ]]; then
        ok "Массовая раздача нод через Skynet завершена."
    else
        warn "Ни для одного сервера ноду в итоге не поставили — смотри сообщения выше."
    fi

    wait_for_enter
}

# === МЕНЮ МОДУЛЯ =============================================

_remna_node_manage_local_menu() {
    while true; do
        clear
        menu_header "Локальная нода Remnawave на этом сервере"
        echo

        local compose_path="/opt/remnanode/docker-compose.yml"

        if [[ ! -f "$compose_path" ]]; then
            echo "   Похоже, локальная нода ещё не установлена через это меню."
            echo "   Не найден docker-compose.yml по пути $compose_path."
            echo
            echo "   [b] 🔙 Назад"
            echo "------------------------------------------------------"
            local ch
            ch=$(safe_read "Твой выбор: " "b")
            case "$ch" in
                [bB]) return ;;
                *)   ;; # любой другой ввод просто перерисует меню
            esac
            continue
        fi

        echo "   [1] Показать статус контейнеров локальной ноды"
        echo "   [2] Перезапустить контейнеры локальной ноды"
        echo "   [3] Смотреть логи локальной ноды (docker compose logs -f)"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "")

        case "$choice" in
            1)
                info "Статус контейнеров локальной ноды (docker compose ps):"
                echo
                ( cd /opt/remnanode && run_cmd docker compose ps ) || err "Не удалось получить статус контейнеров ноды."
                echo
                wait_for_enter
                ;;
            2)
                info "Рестартую контейнеры локальной ноды..."
                if ( cd /opt/remnanode && run_cmd docker compose restart ); then
                    ok "Контейнеры локальной ноды перезапущены."
                else
                    err "docker compose restart для локальной ноды отработал с ошибкой. Смори docker-логи remnanode/remnanode-nginx."
                fi
                echo
                wait_for_enter
                ;;
            3)
                info "Открываю поток логов локальной ноды (CTRL+C, чтобы вернуться)..."
                view_docker_logs "$compose_path" "Remnawave node"
                ;;
            [bB])
                return
                ;;
            *)
                err "Нет такого пункта, смотри внимательнее, босс."
                ;;
        esac
    done
}

show_remnawave_node_menu() {
    while true; do
        clear
        menu_header "Ноды Remnawave (локально и через Skynet)"
        echo
        echo "   [1] Поставить ноду на ЭТОТ сервер"
        echo "   [2] Поставить ноду через Skynet на ОДИН сервер"
        echo "   [3] Раздать ноды через Skynet на НЕСКОЛЬКО серваков"
        echo "   [4] Управление локальной нодой на этом сервере"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "")

        case "$choice" in
            1) _remna_node_install_local_wizard ;;
            2) _remna_node_install_skynet_one ;;
            3) _remna_node_install_skynet_many ;;
            4) _remna_node_manage_local_menu ;;
            [bB]) break ;;
            *) err "Нет такого пункта, смотри внимательнее, босс." ;;
        esac
    done
}
