# shellcheck shell=bash
MOD_SUMMARY='лимиты файловых дескрипторов для сервисов (systemd) и сессий (PAM)'
MOD_GROUP=system
MOD_DEFAULT=1
MOD_DEPS=(preflight)

LIMITS_SYSTEMD='/etc/systemd/system.conf.d/90-ubuntu-bootstrap.conf'
LIMITS_PAM='/etc/security/limits.d/90-ubuntu-bootstrap.conf'

mod_options() {
    opt LIMITS_NOFILE int 65535 'Soft-лимит открытых файлов (nofile); hard 524288 как у systemd'
    opt LIMITS_NPROC int 65535 'Лимит процессов (nproc) для пользователей' adv
}

limits_systemd_render() {
    printf '[Manager]\nDefaultLimitNOFILE=%s:524288\nDefaultLimitNPROC=%s\n' "$(cfg LIMITS_NOFILE)" "$(cfg LIMITS_NPROC)"
}

limits_pam_render() {
    printf '# ubuntu-bootstrap: limits for interactive sessions (applied at login).\n*\tsoft\tnofile\t%s\n*\thard\tnofile\t524288\n*\tsoft\tnproc\t%s\n*\thard\tnproc\t%s\nroot\tsoft\tnofile\t%s\nroot\thard\tnofile\t524288\n' \
        "$(cfg LIMITS_NOFILE)" "$(cfg LIMITS_NPROC)" "$(cfg LIMITS_NPROC)" "$(cfg LIMITS_NOFILE)"
}

mod_check() {
    [[ -f $LIMITS_PAM && $(cat "$LIMITS_PAM") == "$(limits_pam_render)" ]] || return 1
    ((F_HAS_SYSTEMD)) || return 0
    [[ -f $LIMITS_SYSTEMD && $(cat "$LIMITS_SYSTEMD") == "$(limits_systemd_render)" ]] || return 1
    ((F_CONTAINER)) || [[ $(systemctl show -p DefaultLimitNOFILESoft --value 2>/dev/null) == "$(cfg LIMITS_NOFILE)" ]]
}

mod_apply() {
    limits_pam_render | file_write "$LIMITS_PAM" 644
    if ((F_HAS_SYSTEMD)); then
        undo systemctl daemon-reexec
        limits_systemd_render | file_write "$LIMITS_SYSTEMD" 644
        # [Manager] values are read only on daemon-reexec; running services pick them up after a restart.
        [[ ${FILE_CHANGED:-0} == 1 ]] && ((DRY_RUN == 0)) && { run systemctl daemon-reexec || return 1; }
    fi
    log_ok "nofile soft=$(cfg LIMITS_NOFILE) hard=524288 для сервисов (после их перезапуска) и сессий (после входа)"
    return 0
}

mod_verify() { ((DRY_RUN)) || mod_check; }

mod_audit() {
    local v
    v="$(systemctl show -p DefaultLimitNOFILESoft --value 2>/dev/null)"
    [[ -n $v && $v -ge 65535 ]] && check_ok "systemd DefaultLimitNOFILE soft=$v" || check_warn "systemd DefaultLimitNOFILE soft=${v:-?}"
    if has_cmd nginx && svc_active nginx; then
        v="$(systemctl show nginx -p LimitNOFILESoft --value 2>/dev/null)"
        [[ -n $v && $v -ge 65535 ]] && check_ok "nginx LimitNOFILE=$v" || check_warn "nginx LimitNOFILE=${v:-?} (нужен restart после модуля limits/nginx)"
    fi
}
