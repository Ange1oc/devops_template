# shellcheck shell=bash
MOD_SUMMARY='проверка сервера: ОС, права, диск, apt, SSH-сессия'
MOD_GROUP=system
MOD_DEFAULT=1
MOD_ALWAYS=1

mod_options() {
    opt PREFLIGHT_MIN_DISK_GB int 2 'Минимум свободного места на / (GiB)' adv
}

mod_check() { [[ $F_OS_ID == ubuntu ]]; }

mod_apply() {
    [[ $F_OS_ID == ubuntu ]] || { guard_refuse "ОС не Ubuntu (${F_OS_ID:-неизвестно})"; return; }
    case $F_OS_VERSION in
        22.04 | 24.04 | 26.04) log_ok "Ubuntu $F_OS_VERSION LTS ($F_ARCH)" ;;
        *) guard_refuse "Ubuntu $F_OS_VERSION не поддерживается (нужна 22.04/24.04/26.04 LTS)" || return ;;
    esac
    in_list "$F_ARCH" amd64 arm64 || log_warn "архитектура $F_ARCH не тестировалась"
    ((F_HAS_SYSTEMD)) || log_warn 'systemd не обнаружен: сервисы и таймеры отката недоступны'
    ((F_CONTAINER)) && log_warn "запуск внутри контейнера ($F_VIRT): swap, sysctl и snap будут пропущены"
    if ((${F_DISK_FREE_GB:-0} < $(cfg PREFLIGHT_MIN_DISK_GB))); then
        guard_refuse "на / свободно ${F_DISK_FREE_GB} GiB — меньше минимума $(cfg PREFLIGHT_MIN_DISK_GB) GiB" || return
    fi
    is_root && ((DRY_RUN == 0)) && apt_wait 120
    facts_summary
    log_plain '  Слушающие порты:'
    listening_summary >&2
    local sw
    for sw in nginx docker ufw fail2ban certbot wg-network; do
        has_cmd "$sw" && log_plain "  установлен: $sw $("$sw" --version 2>&1 | head -1 | cut -c1-50)"
    done
    return 0
}

mod_audit() {
    [[ $F_OS_ID == ubuntu ]] && check_ok "ОС Ubuntu $F_OS_VERSION" || check_fail "ОС ${F_OS_ID:-?}"
}
