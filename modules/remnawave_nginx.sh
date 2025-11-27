#!/bin/bash
# ============================================================ #
# ==      REMNAWAVE: ОБЩИЕ ШАБЛОНЫ NGINX-КОНФИГУРАЦИЙ       == #
# ============================================================ #
# Здесь собраны функции, которые пишут nginx.conf для разных
# сценариев Remnawave:
#   - панель+нода на один сервер (HTTP без TLS);
#   - только панель (HTTP без TLS);
#   - локальная нода (HTTP маскировка на 80 порту).
#
# Идея: визарды установки и управления не держат у себя громоздкие
# шаблоны nginx, а просто вызывают remna_nginx_write_* с нужными
# доменами и каталогом.
#
# На будущее здесь можно будет добавить режимы стека (cookie/plain
# и т.п.), а также полные HTTPS-конфиги.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# --- Панель+нода на один сервер: HTTP-вариант -------------------
# target_dir      — каталог проекта (обычно /opt/remnawave)
# panel_domain    — домен панели
# sub_domain      — домен страницы подписки
# selfsteal_domain — маскировочный домен selfsteal-ноды
remna_nginx_write_panel_node_http() {
    local target_dir="$1"
    local panel_domain="$2"
    local sub_domain="$3"
    local selfsteal_domain="$4"

    mkdir -p "$target_dir" || return 1

    cat >"$target_dir/nginx.conf" <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

# Управляем апгрейдом соединения (WebSocket и т.п.)
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

server {
    listen 80;
    server_name $panel_domain;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}

server {
    listen 80;
    server_name $sub_domain;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}

server {
    listen 80;
    server_name $selfsteal_domain;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}
EOL
}

# --- Только панель: HTTP-вариант -------------------------------
# target_dir   — каталог проекта (обычно /opt/remnawave)
# panel_domain — домен панели
# sub_domain   — домен страницы подписки
remna_nginx_write_panel_only_http() {
    local target_dir="$1"
    local panel_domain="$2"
    local sub_domain="$3"

    mkdir -p "$target_dir" || return 1

    cat >"$target_dir/nginx.conf" <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

# Управляем апгрейдом соединения (WebSocket и т.п.)
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

server {
    listen 80;
    server_name $panel_domain;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}

server {
    listen 80;
    server_name $sub_domain;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}
EOL
}

# --- Локальная нода: HTTP-маскировка ---------------------------
# target_dir       — каталог окружения ноды (обычно /opt/remnanode)
# selfsteal_domain — маскировочный домен ноды
remna_nginx_write_node_http() {
    local target_dir="$1"
    local selfsteal_domain="$2"

    mkdir -p "$target_dir" || return 1

    cat >"$target_dir/nginx.conf" <<EOL
server {
    listen 80;
    server_name $selfsteal_domain;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}
EOL
}

# --- Панель+нода: HTTPS c куки-защитой панели -------------------
# target_dir         — каталог проекта (обычно /opt/remnawave)
# panel_domain       — домен панели
# sub_domain         — домен страницы подписки
# selfsteal_domain   — маскировочный домен selfsteal-ноды (HTTP остаётся)
# panel_cert_domain  — домен каталога certbot для панели (panel или base)
# sub_cert_domain    — домен каталога certbot для сабы
# cookies_random1/2  — пара значений для куки-защиты
remna_nginx_write_panel_node_tls_cookie() {
    local target_dir="$1"
    local panel_domain="$2"
    local sub_domain="$3"
    local selfsteal_domain="$4"
    local panel_cert_domain="$5"
    local sub_cert_domain="$6"
    local cookies_random1="$7"
    local cookies_random2="$8"

    mkdir -p "$target_dir" || return 1

    cat >"$target_dir/nginx.conf" <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

# Управляем апгрейдом соединения (WebSocket и т.п.)
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

# Cookie-защита панели: вход только по спецссылке с "одноразовым ключом".
map \$http_cookie \$auth_cookie {
    default 0;
    "~*${cookies_random1}=${cookies_random2}" 1;
}

map \$arg_${cookies_random1} \$auth_query {
    default 0;
    "${cookies_random2}" 1;
}

map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}

map \$arg_${cookies_random1} \$set_cookie_header {
    "${cookies_random2}" "${cookies_random1}=${cookies_random2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

# Перенаправляем HTTP-запросы панели и страницы подписки на HTTPS
server {
    listen 80;
    server_name $panel_domain;

    return 301 https://$panel_domain\$request_uri;
}

server {
    listen 80;
    server_name $sub_domain;

    return 301 https://$sub_domain\$request_uri;
}

# Selfsteal-домен остаётся HTTP: маскировочный сайт
server {
    listen 80;
    server_name $selfsteal_domain;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    server_name $panel_domain;
    listen 443 ssl http2;

    ssl_certificate "/etc/letsencrypt/live/$panel_cert_domain/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$panel_cert_domain/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/$panel_cert_domain/fullchain.pem";

    add_header Set-Cookie \$set_cookie_header;

    location / {
        error_page 418 = @unauthorized;
        recursive_error_pages on;
        if (\$authorized = 0) {
            return 418;
        }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location @unauthorized {
        root /var/www/html;
        index index.html;
    }
}

server {
    server_name $sub_domain;
    listen 443 ssl http2;

    ssl_certificate "/etc/letsencrypt/live/$sub_cert_domain/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$sub_cert_domain/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/$sub_cert_domain/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 404;
    }
}

# Защита по умолчанию для прочих хостов: TLS-рукопожатие сразу режем
server {
    listen 443 ssl http2 default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL
}

# --- Панель+нода: HTTPS без куки-защиты (простой режим) ---------
# Та же структура, но без map/authorized и Set-Cookie.
remna_nginx_write_panel_node_tls_plain() {
    local target_dir="$1"
    local panel_domain="$2"
    local sub_domain="$3"
    local selfsteal_domain="$4"
    local panel_cert_domain="$5"
    local sub_cert_domain="$6"

    mkdir -p "$target_dir" || return 1

    cat >"$target_dir/nginx.conf" <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

# Управляем апгрейдом соединения (WebSocket и т.п.)
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    listen 80;
    server_name $panel_domain;

    return 301 https://$panel_domain\$request_uri;
}

server {
    listen 80;
    server_name $sub_domain;

    return 301 https://$sub_domain\$request_uri;
}

# Selfsteal-домен остаётся HTTP: маскировочный сайт
server {
    listen 80;
    server_name $selfsteal_domain;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    server_name $panel_domain;
    listen 443 ssl http2;

    ssl_certificate "/etc/letsencrypt/live/$panel_cert_domain/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$panel_cert_domain/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/$panel_cert_domain/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

server {
    server_name $sub_domain;
    listen 443 ssl http2;

    ssl_certificate "/etc/letsencrypt/live/$sub_cert_domain/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$sub_cert_domain/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/$sub_cert_domain/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 404;
    }
}

server {
    listen 443 ssl http2 default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL
}

# --- Только панель: HTTPS с куки-защитой ------------------------
# target_dir        — /opt/remnawave
# panel_domain      — домен панели
# sub_domain        — домен подписки
# panel_cert_domain — каталог certbot панели
# sub_cert_domain   — каталог certbot сабы
# cookies_random1/2 — пара значений для куки-защиты
remna_nginx_write_panel_only_tls_cookie() {
    local target_dir="$1"
    local panel_domain="$2"
    local sub_domain="$3"
    local panel_cert_domain="$4"
    local sub_cert_domain="$5"
    local cookies_random1="$6"
    local cookies_random2="$7"

    mkdir -p "$target_dir" || return 1

    cat >"$target_dir/nginx.conf" <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

# Управляем апгрейдом соединения (WebSocket и т.п.)
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

# Cookie-защита панели: вход только по спецссылке с "одноразовым ключом".
map \$http_cookie \$auth_cookie {
    default 0;
    "~*${cookies_random1}=${cookies_random2}" 1;
}

map \$arg_${cookies_random1} \$auth_query {
    default 0;
    "${cookies_random2}" 1;
}

map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}

map \$arg_${cookies_random1} \$set_cookie_header {
    "${cookies_random2}" "${cookies_random1}=${cookies_random2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;

server {
    listen 80;
    server_name $panel_domain;

    return 301 https://$panel_domain\$request_uri;
}

server {
    listen 80;
    server_name $sub_domain;

    return 301 https://$sub_domain\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $panel_domain;

    ssl_certificate     /etc/letsencrypt/live/$panel_cert_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$panel_cert_domain/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$panel_cert_domain/fullchain.pem;

    add_header Set-Cookie \$set_cookie_header;

    location / {
        if (\$authorized = 0) {
            return 444;
        }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

server {
    listen 443 ssl http2;
    server_name $sub_domain;

    ssl_certificate     /etc/letsencrypt/live/$sub_cert_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$sub_cert_domain/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$sub_cert_domain/fullchain.pem;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 404;
    }
}

# Защита по умолчанию для прочих хостов: TLS-рукопожатие сразу режем
server {
    listen 443 ssl http2 default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL
}

# --- Только панель: HTTPS без куки-защиты -----------------------
remna_nginx_write_panel_only_tls_plain() {
    local target_dir="$1"
    local panel_domain="$2"
    local sub_domain="$3"
    local panel_cert_domain="$4"
    local sub_cert_domain="$5"

    mkdir -p "$target_dir" || return 1

    cat >"$target_dir/nginx.conf" <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

# Управляем апгрейдом соединения (WebSocket и т.п.)
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;

server {
    listen 80;
    server_name $panel_domain;

    return 301 https://$panel_domain\$request_uri;
}

server {
    listen 80;
    server_name $sub_domain;

    return 301 https://$sub_domain\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $panel_domain;

    ssl_certificate     /etc/letsencrypt/live/$panel_cert_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$panel_cert_domain/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$panel_cert_domain/fullchain.pem;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

server {
    listen 443 ssl http2;
    server_name $sub_domain;

    ssl_certificate     /etc/letsencrypt/live/$sub_cert_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$sub_cert_domain/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$sub_cert_domain/fullchain.pem;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 404;
    }
}

server {
    listen 443 ssl http2 default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL
}

# --- Локальная нода: HTTPS c сертификатом Let's Encrypt ---------
# target_dir       — /opt/remnanode
# selfsteal_domain — домен маскировочного сайта ноды
# cert_domain      — каталог certbot (сам домен или базовый)
remna_nginx_write_node_tls() {
    local target_dir="$1"
    local selfsteal_domain="$2"
    local cert_domain="$3"

    mkdir -p "$target_dir" || return 1

    cat >"$target_dir/nginx.conf" <<EOL
server {
    listen 80;
    server_name $selfsteal_domain;

    return 301 https://$selfsteal_domain\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $selfsteal_domain;

    ssl_certificate     /etc/letsencrypt/live/$cert_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$cert_domain/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}
EOL
}
