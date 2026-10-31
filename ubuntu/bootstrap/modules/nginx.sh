# shellcheck shell=bash
MOD_SUMMARY='nginx из Ubuntu или nginx.org (stable/mainline), базовый hardening, лимиты'
MOD_GROUP=services
MOD_DEPS=(preflight base)

NGINX_KEY_FPR='573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62'
NGINX_TUNING='/etc/nginx/conf.d/00-ubuntu-bootstrap.conf'
NGINX_SNIPPET='/etc/nginx/snippets/security-headers.conf'

mod_options() {
    opt NGINX_SOURCE enum:ubuntu,stable,mainline stable 'Источник: ubuntu (патчи Canonical, версия заморожена), nginx.org stable (рекомендуется), mainline'
    opt NGINX_VERSION string '' 'Версия пакета (пусто — последняя; apt-cache madison nginx)' adv
    opt NGINX_SERVER_TOKENS bool no 'Показывать версию nginx в заголовках и ошибках' adv
    opt NGINX_SECURITY_SNIPPET bool yes 'Создать snippets/security-headers.conf (OWASP, подключается в server{})'
    opt NGINX_CLIENT_MAX_BODY size 20M 'client_max_body_size по умолчанию' adv
    opt NGINX_DISABLE_DEFAULT_SITE bool no 'Отключить сайт по умолчанию (default / default.conf)' adv
}

nginx_flavor_installed() {
    pkg_installed nginx || return 1
    [[ $(apt-cache policy nginx 2>/dev/null | grep -A1 '\*\*\*' | tail -1) == *nginx.org* ]] && printf 'nginx.org' || printf 'ubuntu'
}

nginx_tuning_render() {
    cat <<EOT
# ubuntu-bootstrap: shared http{} settings (worker_* come from the package nginx.conf).
server_tokens $(cfg_bool NGINX_SERVER_TOKENS && echo on || echo off);
client_max_body_size $(cfg NGINX_CLIENT_MAX_BODY | tr '[:upper:]' '[:lower:]');
client_body_timeout 30s;
client_header_timeout 30s;
send_timeout 30s;
keepalive_requests 1000;
# Mozilla SSL Configuration Generator, intermediate profile (ssl.mozilla.org)
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_session_timeout 1d;
ssl_session_cache shared:ubb_ssl:10m;
ssl_session_tickets off;
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;
map \$http_upgrade \$ubb_connection_upgrade { default upgrade; '' close; }
EOT
}

nginx_snippet_render() {
    cat <<'EOT'
# ubuntu-bootstrap: baseline headers (OWASP Secure Headers). In server{}: include snippets/security-headers.conf;
# CSP and HSTS are deliberately absent: they are site-specific (certbot --hsts adds HSTS).
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
EOT
}

mod_check() {
    pkg_installed nginx || return 1
    [[ -f $NGINX_TUNING && $(cat "$NGINX_TUNING") == "$(nginx_tuning_render)" ]] || return 1
    ! cfg_bool NGINX_SECURITY_SNIPPET || [[ -f $NGINX_SNIPPET ]] || return 1
    svc_active nginx
}

mod_apply() {
    local src flavor ver_arg=''
    src="$(cfg NGINX_SOURCE)"
    flavor="$(nginx_flavor_installed)" || flavor=''
    if [[ -n $flavor ]]; then
        log_ok "nginx уже установлен ($flavor, $(nginx -v 2>&1 | grep -oE '[0-9.]+$'))"
        if [[ $src != ubuntu && $flavor == ubuntu ]] || [[ $src == ubuntu && $flavor == nginx.org ]]; then
            log_warn "установлен nginx из $flavor, а в конфиге NGINX_SOURCE=$src: источник не меняю (разные пути конфигов). Переустанови вручную при необходимости"
        fi
    else
        if [[ $src != ubuntu ]]; then
            local url=https://nginx.org/packages/ubuntu
            [[ $src == mainline ]] && url=https://nginx.org/packages/mainline/ubuntu
            apt_install ca-certificates curl gnupg || return 1
            apt_repo_add nginx "$url" "$F_OS_CODENAME" nginx https://nginx.org/keys/nginx_signing.key "$NGINX_KEY_FPR" || return 1
            printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' | file_write /etc/apt/preferences.d/99nginx 644
        fi
        if [[ -n $(cfg NGINX_VERSION) ]]; then
            apt_update
            apt-cache madison nginx 2>/dev/null | grep -qF "$(cfg NGINX_VERSION)" || { log_error "версия nginx $(cfg NGINX_VERSION) недоступна"; return 1; }
            ver_arg="=$(cfg NGINX_VERSION)"
        fi
        undo systemctl disable --now nginx
        apt_install "nginx$ver_arg" || return 1
    fi
    undo nginx_reload_if_valid
    ((DRY_RUN)) || install -d -m 755 /etc/nginx/conf.d /etc/nginx/snippets
    nginx_tuning_render | file_write "$NGINX_TUNING" 644
    local changed=${FILE_CHANGED:-0}
    if cfg_bool NGINX_SECURITY_SNIPPET; then nginx_snippet_render | file_write "$NGINX_SNIPPET" 644; fi
    if cfg_bool NGINX_DISABLE_DEFAULT_SITE; then
        [[ -L /etc/nginx/sites-enabled/default ]] && { undo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default; run rm -f /etc/nginx/sites-enabled/default; changed=1; }
        [[ -f /etc/nginx/conf.d/default.conf ]] && { file_remove /etc/nginx/conf.d/default.conf; changed=1; }
    fi
    svc_dropin nginx.service ubuntu-bootstrap <<< $'[Service]\nLimitNOFILE=65535'
    ((DRY_RUN)) && return 0
    if ! nginx -t >> "$LOG_FILE" 2>&1; then
        log_error "nginx -t: $(nginx -t 2>&1 | tail -2)"
        return 1
    fi
    svc_enable_now nginx || return 1
    ((changed)) && { run systemctl reload nginx || return 1; }
    log_ok "nginx $(nginx -v 2>&1 | grep -oE '[0-9.]+$') активен; конфиг валиден"
    return 0
}

nginx_reload_if_valid() {
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
}

mod_verify() { ((DRY_RUN)) || { nginx -t >/dev/null 2>&1 && svc_active nginx; }; }

mod_audit() {
    has_cmd nginx || { check_info 'nginx не установлен'; return 0; }
    nginx -t >/dev/null 2>&1 && check_ok "nginx $(nginx -v 2>&1 | grep -oE '[0-9.]+$'): конфиг валиден" || check_fail 'nginx -t: конфиг невалиден'
    svc_active nginx && check_ok 'nginx активен' || check_fail 'nginx не запущен'
    grep -rqsE '^\s*server_tokens\s+off' /etc/nginx/ && check_ok 'server_tokens off' || check_warn 'версия nginx раскрывается (server_tokens)'
    grep -rqsE '^\s*ssl_protocols.*TLSv1(\.1)?[ ;]' /etc/nginx/ && check_warn 'разрешены TLSv1/1.1' || check_ok 'нет устаревших TLS-протоколов в конфиге'
    local n
    n="$(grep -rlsE '^\s*server_name' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | wc -l)"
    check_info "сайтов: $n"
    return 0
}
