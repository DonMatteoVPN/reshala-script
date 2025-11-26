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

_remna_node_install_local_wizard() {
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

# Проверка, что в панели ещё нет ноды с таким доменом
_remna_node_api_check_node_domain() {
    menu_header "Нода Remnawave на этот сервак"
    echo
    echo "   Ставим НОДУ для уже существующей панели."
    echo "   Панель может быть тут или на другом сервере."
    echo

    local PANEL_API PANEL_API_TOKEN SELFSTEAL_DOMAIN NODE_NAME
    PANEL_API=$(safe_read "API панели (host:port, по умолчанию 127.0.0.1:3000): " "127.0.0.1:3000")
    PANEL_API_TOKEN=$(safe_read "API токен панели (создай в разделе API Tokens): " "")
    SELFSTEAL_DOMAIN=$(safe_read "Selfsteal домен ноды (node.example.com): " "")
    NODE_NAME=$(safe_read "Имя ноды в панели (например Germany-1): " "")

    if [[ -з "$SELFSTEAL_DOMAIN" || -з "$NODE_NAME" ]]; then
        err "Имя ноды и домен — обязательно."
        return 1
    fi
    if [[ -з "$PANEL_API_TOKEN" ]]; then
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

    info "Готовлю /opt/remnanode и HTTP-окружение ноды (без TLS, только маскировка)..."
    if ! _remna_node_prepare_runtime_dir; then
        err "Не смог подготовить директорию /opt/remnanode. Смотри логи."
        return 1
    fi

    _remna_node_write_runtime_compose_and_nginx "$SELFSTEAL_DOMAIN" || {
        err "Не смог собрать docker-compose.yml и nginx.conf для ноды."
        return 1
    }

    info "Получаю публичный ключ ноды из панели и прошиваю его в SECRET_KEY..."
    _remna_node_api_apply_public_key "$domain_url" "$PANEL_API_TOKEN" "/opt/remnanode/docker-compose.yml" || return 1

    info "Стартую Docker-композ локальной ноды (HTTP-режим)..."
    (
        cd /opt/remnanode && run_cmd docker compose up -d
    ) || {
        err "docker compose up -d для локальной ноды отработал с ошибкой. Смотри docker-логи remnanode/remnanode-nginx."
        return 1
    }

    ok "Локальная нода поднята: маскировочный сайт крутится на http://$SELFSTEAL_DOMAIN. SECRET_KEY уже получен из панели, TLS прикрутим на следующем этапе."
    wait_for_enter
}

_remna_node_install_skynet_one() {
    clear
    menu_header "Нода Remnawave через Skynet (один сервер)"
    echo
    echo "   Тут выберем один сервак из флота и воткнём туда ноду."
    echo
    warn "Пока только каркас. Выбор сервера и запуск плагина ещё впереди."
    wait_for_enter
}

_remna_node_install_skynet_many() {
    clear
    menu_header "Ноды Remnawave через Skynet (несколько серверов)"
    echo
    echo "   Раздаём ноды пачкой по выбранным серверам Skynet."
    echo
    warn "Пока только каркас. Массовая установка ещё не реализована."
    wait_for_enter
}

# === МЕНЮ МОДУЛЯ =============================================

show_remnawave_node_menu() {
    while true; do
        clear
        menu_header "Ноды Remnawave (локально и через Skynet)"
        echo
        echo "   [1] Поставить ноду на ЭТОТ сервер"
        echo "   [2] Поставить ноду через Skynet на ОДИН сервер"
        echo "   [3] Раздать ноды через Skynet на НЕСКОЛЬКО серваков"
        echo
        echo "   [b] 🔙 Назад"
        echo "------------------------------------------------------"

        local choice
        choice=$(safe_read "Твой выбор: " "")

        case "$choice" in
            1) _remna_node_install_local_wizard ;;
            2) _remna_node_install_skynet_one ;;
            3) _remna_node_install_skynet_many ;;
            [bB]) break ;;
            *) err "Нет такого пункта, смотри внимательнее, босс." ;;
        esac
    done
}
