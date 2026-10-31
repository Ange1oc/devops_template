# shellcheck shell=bash
MOD_SUMMARY='journald: постоянный журнал с лимитами размера и срока хранения'
MOD_GROUP=system
MOD_DEFAULT=1
MOD_DEPS=(preflight)

JOURNALD_CONF='/etc/systemd/journald.conf.d/90-ubuntu-bootstrap.conf'

mod_options() {
    opt JOURNALD_MAX_USE size 1G 'Максимальный объём журнала на диске'
    opt JOURNALD_MAX_FILE size 128M 'Размер одного файла журнала' adv
    opt JOURNALD_RETENTION duration 1month 'Срок хранения (напр. 2weeks, 1month)' adv
    opt JOURNALD_FORWARD_SYSLOG enum:auto,yes,no auto 'Дублировать в rsyslog (auto — если rsyslog установлен)' adv
}

journald_render() {
    local fwd
    case $(cfg JOURNALD_FORWARD_SYSLOG) in
        yes) fwd=yes ;;
        no) fwd=no ;;
        *) pkg_installed rsyslog && fwd=yes || fwd=no ;;
    esac
    printf '[Journal]\nStorage=persistent\nCompress=yes\nSystemMaxUse=%s\nSystemMaxFileSize=%s\nMaxRetentionSec=%s\nForwardToSyslog=%s\nRateLimitIntervalSec=30s\nRateLimitBurst=10000\n' \
        "$(cfg JOURNALD_MAX_USE)" "$(cfg JOURNALD_MAX_FILE)" "$(cfg JOURNALD_RETENTION)" "$fwd"
}

mod_check() {
    ((F_HAS_SYSTEMD)) || return 0
    [[ -f $JOURNALD_CONF && $(cat "$JOURNALD_CONF") == "$(journald_render)" ]] && [[ -d /var/log/journal ]]
}

mod_apply() {
    ((F_HAS_SYSTEMD)) || { log_warn 'нет systemd — journald не настраивается'; return 0; }
    undo systemctl restart systemd-journald
    journald_render | file_write "$JOURNALD_CONF" 644
    if [[ ! -d /var/log/journal ]] && ((DRY_RUN == 0)); then
        install -d -m 2755 -g systemd-journal /var/log/journal
        run systemd-tmpfiles --create --prefix /var/log/journal || true
    fi
    [[ ${FILE_CHANGED:-0} == 1 ]] && ((DRY_RUN == 0)) && { run systemctl restart systemd-journald || return 1; }
    log_ok "journald: persistent, до $(cfg JOURNALD_MAX_USE), хранение $(cfg JOURNALD_RETENTION)"
    return 0
}

mod_verify() { ((DRY_RUN)) || mod_check; }

mod_audit() {
    ((F_HAS_SYSTEMD)) || return 0
    [[ -d /var/log/journal ]] && check_ok "журнал постоянный, занято $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[A-Z]')" || check_warn 'журнал только в памяти (пропадает при перезагрузке)'
    pkg_installed logrotate && check_ok 'logrotate установлен' || check_warn 'logrotate не установлен'
}
