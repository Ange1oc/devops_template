# shellcheck shell=bash
MOD_SUMMARY="TLS от Let's Encrypt: certbot, выпуск для доменов, авто-продление"
MOD_GROUP=services
MOD_DEPS=(preflight)
MOD_AFTER=(nginx firewall)

mod_options() {
    opt CERTBOT_METHOD enum:auto,snap,apt auto 'Установка: snap (рекомендация EFF, всегда свежий) или apt; auto — snap, если доступен'
    opt CERTBOT_DOMAINS hostnames '' 'Домены для сертификата (первый — основной); пусто — только установить certbot'
    opt CERTBOT_EMAIL email '' "E-mail для уведомлений Let's Encrypt об истечении"
    opt CERTBOT_REDIRECT bool yes 'Включить редирект HTTP→HTTPS'
    opt CERTBOT_HSTS bool no 'Добавить заголовок HSTS (включай, когда уверен, что HTTPS навсегда)' adv
    opt CERTBOT_STAGING bool no 'Тестовый ACME-сервер (staging): без лимитов, сертификат не доверенный' adv
    opt CERTBOT_DNS_CHECK bool yes 'Перед выпуском проверить, что A-записи указывают на этот сервер' adv
}

mod_wizard() {
    log_plain "  HTTP-01 challenge требует: DNS домена -> этот сервер, порт 80 открыт, nginx отвечает."
}

certbot_installed() { has_cmd certbot || [[ -x /snap/bin/certbot ]]; }

certbot_method() {
    local m
    m="$(cfg CERTBOT_METHOD)"
    [[ $m == auto ]] && { snap_usable && m=snap || m=apt; }
    printf '%s' "$m"
}

certbot_site_conf() {
    local primary=$1
    if [[ -d /etc/nginx/sites-available ]]; then printf '/etc/nginx/sites-available/%s.conf' "$primary"; else printf '/etc/nginx/conf.d/%s.conf' "$primary"; fi
}

mod_check() {
    certbot_installed || return 1
    local -a domains=()
    cfg_list CERTBOT_DOMAINS domains
    ((${#domains[@]} == 0)) || [[ -d /etc/letsencrypt/live/${domains[0]} ]]
}

certbot_install() {
    certbot_installed && { log_ok "certbot уже установлен: $(certbot --version 2>&1 | head -1)"; return 0; }
    case $(certbot_method) in
        snap)
            apt_install snapd || return 1
            run snap install core 2>/dev/null || true
            undo snap remove certbot
            snap_install certbot --classic || return 1
            ((DRY_RUN)) || ln -sf /snap/bin/certbot /usr/bin/certbot
            ;;
        apt)
            ((F_CONTAINER)) && [[ $(cfg CERTBOT_METHOD) == auto ]] && log_info 'контейнер: snap недоступен, ставлю certbot из apt'
            apt_install certbot python3-certbot-nginx || return 1
            ;;
    esac
    log_ok "certbot установлен ($(certbot_method))"
}

certbot_dns_ok() {
    local d ip my fail=0
    my="$(public_ip)"
    for d in "$@"; do
        ip="$(getent ahostsv4 "$d" 2>/dev/null | awk '{ print $1; exit }')"
        if [[ -z $ip ]]; then log_warn "DNS: $d не резолвится"; fail=1
        elif [[ $ip != "$my" ]]; then log_warn "DNS: $d -> $ip, а сервер видит себя как $my"; fail=1
        else log_ok "DNS: $d -> $ip"; fi
    done
    return "$fail"
}

mod_apply() {
    local -a domains=() args=()
    local primary d site
    certbot_install || return 1
    cfg_list CERTBOT_DOMAINS domains
    ((${#domains[@]})) || { log_info 'CERTBOT_DOMAINS пуст — сертификат не выпускается'; return 0; }
    has_cmd nginx || { log_error 'для certbot --nginx нужен nginx (модуль nginx)'; return 1; }
    primary=${domains[0]}
    if [[ -d /etc/letsencrypt/live/$primary ]]; then
        log_ok "сертификат для $primary уже есть; проверяю продление"
        ((DRY_RUN)) || run certbot renew --dry-run || log_warn 'certbot renew --dry-run завершился с ошибкой'
        return 0
    fi
    if cfg_bool CERTBOT_DNS_CHECK && ! certbot_dns_ok "${domains[@]}"; then
        guard_refuse 'DNS не готов: HTTP-01 challenge не пройдёт (CERTBOT_DNS_CHECK=no отключает проверку)' || return
    fi
    port_listening 80 || log_warn 'порт 80 никем не слушается'

    if ! grep -rqsE "server_name[^;]*\b${primary//./\\.}\b" /etc/nginx/ 2>/dev/null; then
        site="$(certbot_site_conf "$primary")"
        log_info "в nginx нет server_name $primary — создаю минимальный HTTP-сайт $site"
        undo nginx_reload_if_valid
        cat <<EOT | file_write "$site" 644
# ubuntu-bootstrap: minimal site for certificate issuance; certbot --nginx adds TLS to it.
server {
    listen 80;
    listen [::]:80;
    server_name ${domains[*]};
    root /var/www/html;
    include snippets/security-headers.conf;
    location / { return 200 "ok\n"; add_header Content-Type text/plain; }
}
EOT
        [[ -d /etc/nginx/sites-enabled && ! -e /etc/nginx/sites-enabled/$primary.conf ]] && run ln -s "$site" "/etc/nginx/sites-enabled/$primary.conf"
        ((DRY_RUN)) || { nginx -t >> "$LOG_FILE" 2>&1 && run systemctl reload nginx || { log_error 'nginx не принял минимальный конфиг'; return 1; }; }
    fi
    for d in "${domains[@]}"; do args+=(-d "$d"); done
    [[ -n $(cfg CERTBOT_EMAIL) ]] && args+=(-m "$(cfg CERTBOT_EMAIL)") || args+=(--register-unsafely-without-email)
    cfg_bool CERTBOT_REDIRECT && args+=(--redirect) || args+=(--no-redirect)
    cfg_bool CERTBOT_HSTS && args+=(--hsts)
    cfg_bool CERTBOT_STAGING && args+=(--staging)
    ((DRY_RUN)) && { log_plain "[dry-run] certbot --nginx ${args[*]} --agree-tos --no-eff-email --non-interactive"; return 0; }
    file_snapshot "$(certbot_site_conf "$primary")"
    undo nginx_reload_if_valid
    run certbot --nginx "${args[@]}" --agree-tos --no-eff-email --non-interactive --keep-until-expiring ||
        { log_error 'выпуск не удался: типичные причины — DNS, закрытый порт 80, rate limit (используй CERTBOT_STAGING=yes для отладки)'; return 1; }
    log_ok "сертификат выпущен для ${domains[*]}"
    run certbot renew --dry-run && log_ok 'тест продления пройден' || log_warn 'certbot renew --dry-run завершился с ошибкой'
    return 0
}

mod_verify() { ((DRY_RUN)) || certbot_installed; }

mod_audit() {
    certbot_installed || { check_info 'certbot не установлен'; return 0; }
    if ((F_HAS_SYSTEMD)); then
        systemctl list-timers --all --no-legend 2>/dev/null | grep -qE 'certbot|snap\.certbot' && check_ok 'таймер продления certbot активен' || check_warn 'таймер продления certbot не найден'
    fi
    local d exp days
    for d in /etc/letsencrypt/live/*/cert.pem; do
        [[ -f $d ]] || continue
        exp="$(openssl x509 -enddate -noout -in "$d" 2>/dev/null | cut -d= -f2)"
        days=$((($(date -d "$exp" +%s) - $(now_epoch)) / 86400))
        ((days > 14)) && check_ok "сертификат $(basename "$(dirname "$d")"): ${days} дн." || check_warn "сертификат $(basename "$(dirname "$d")") истекает через ${days} дн."
    done
    return 0
}
