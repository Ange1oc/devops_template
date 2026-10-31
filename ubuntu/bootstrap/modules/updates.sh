# shellcheck shell=bash
MOD_SUMMARY='автоматические security-обновления (unattended-upgrades)'
MOD_GROUP=security
MOD_DEFAULT=1
MOD_DEPS=(preflight)

UPD_CONF='/etc/apt/apt.conf.d/52ubuntu-bootstrap-unattended'
UPD_PERIODIC='/etc/apt/apt.conf.d/20auto-upgrades'

mod_options() {
    opt UPD_ORIGINS enum:security,all security 'Что обновлять: security — только security-pocket, all — и -updates'
    opt UPD_AUTO_REBOOT bool no 'Автоматическая перезагрузка, если её требует обновление'
    opt UPD_REBOOT_TIME string '04:00' 'Время перезагрузки (локальное, HH:MM)' adv
    opt UPD_REMOVE_UNUSED bool yes 'Удалять ненужные зависимости и старые ядра' adv
    opt UPD_SCHEDULE string '' 'Своё расписание (systemd OnCalendar, напр. "Sun *-*-* 04:00"); пусто — ежедневно, как в Ubuntu' adv
    opt UPD_MAIL email '' 'E-mail для отчётов (нужен настроенный MTA)' adv
}

upd_render() {
    cat <<EOT
// ubuntu-bootstrap. Default Allowed-Origins (50unattended-upgrades): release and -security.
// Docs: ubuntu.com/server/docs/how-to/software/automatic-updates
EOT
    if [[ $(cfg UPD_ORIGINS) == all ]]; then
        # shellcheck disable=SC2016  # ${distro_id} is expanded by unattended-upgrades itself
        printf 'Unattended-Upgrade::Allowed-Origins {\n    "${distro_id}:${distro_codename}-updates";\n};\n'
    fi
    cat <<EOT
Unattended-Upgrade::Automatic-Reboot "$(cfg_bool UPD_AUTO_REBOOT && echo true || echo false)";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "$(cfg UPD_REBOOT_TIME)";
Unattended-Upgrade::Remove-Unused-Dependencies "$(cfg_bool UPD_REMOVE_UNUSED && echo true || echo false)";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "$(cfg_bool UPD_REMOVE_UNUSED && echo true || echo false)";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
EOT
    [[ -n $(cfg UPD_MAIL) ]] && printf 'Unattended-Upgrade::Mail "%s";\nUnattended-Upgrade::MailReport "on-change";\n' "$(cfg UPD_MAIL)"
    return 0
}

upd_periodic_render() {
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n'
}

upd_timer_render() {
    local cal=$1 shift_min=$2
    printf '[Timer]\nOnCalendar=\nOnCalendar=%s\nRandomizedDelaySec=%s\nPersistent=true\n' "$cal" "$shift_min"
}

mod_check() {
    pkg_installed unattended-upgrades || return 1
    [[ -f $UPD_CONF && $(cat "$UPD_CONF") == "$(upd_render)" ]] || return 1
    [[ -f $UPD_PERIODIC && $(cat "$UPD_PERIODIC") == "$(upd_periodic_render)" ]] || return 1
    ((F_HAS_SYSTEMD)) && ((F_CONTAINER == 0)) && { svc_active apt-daily-upgrade.timer || return 1; }
    return 0
}

mod_apply() {
    local cal
    apt_install unattended-upgrades || return 1
    upd_render | file_write "$UPD_CONF" 644
    upd_periodic_render | file_write "$UPD_PERIODIC" 644
    cal="$(cfg UPD_SCHEDULE)"
    if [[ -n $cal ]]; then
        if ((DRY_RUN == 0)) && ! systemd-analyze calendar "$cal" >/dev/null 2>&1; then
            log_error "UPD_SCHEDULE: systemd не понимает расписание '$cal'"
            return 1
        fi
        svc_dropin apt-daily.timer ubuntu-bootstrap < <(upd_timer_render "$cal" 10m)
        svc_dropin apt-daily-upgrade.timer ubuntu-bootstrap < <(upd_timer_render "$cal" 30m)
    else
        local f removed=0
        for f in /etc/systemd/system/apt-daily.timer.d/ubuntu-bootstrap.conf /etc/systemd/system/apt-daily-upgrade.timer.d/ubuntu-bootstrap.conf; do
            [[ -f $f ]] && { file_remove "$f"; removed=1; }
        done
        ((removed)) && svc_daemon_reload
    fi
    ((DRY_RUN)) && return 0
    if ! apt-config dump >/dev/null 2>> "$LOG_FILE"; then
        log_error 'apt-config не принимает конфигурацию'
        return 1
    fi
    if ((F_HAS_SYSTEMD)) && ((F_CONTAINER == 0)); then
        svc_enable_now apt-daily.timer && svc_enable_now apt-daily-upgrade.timer || return 1
        run systemctl restart apt-daily.timer apt-daily-upgrade.timer || true
    fi
    log_ok "unattended-upgrades: $(cfg UPD_ORIGINS), авто-перезагрузка $(cfg UPD_AUTO_REBOOT)${cal:+, расписание $cal}"
    return 0
}

mod_verify() { ((DRY_RUN)) || mod_check; }

mod_audit() {
    pkg_installed unattended-upgrades || { check_fail 'unattended-upgrades не установлен'; return 0; }
    local v
    v="$(apt-config dump 2>/dev/null | awk -F'"' '/^APT::Periodic::Unattended-Upgrade / { print $2 }')"
    [[ ${v:-0} != 0 ]] && check_ok "автообновления включены (каждые $v дн.)" || check_fail 'автообновления выключены (APT::Periodic::Unattended-Upgrade 0)'
    if ((F_HAS_SYSTEMD)) && ((F_CONTAINER == 0)); then
        svc_active apt-daily-upgrade.timer && check_ok "таймер apt-daily-upgrade: $(systemctl show apt-daily-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null)" || check_fail 'таймер apt-daily-upgrade не активен'
    fi
    v="$(apt-config dump 2>/dev/null | awk -F'"' '/^Unattended-Upgrade::Automatic-Reboot / { print $2 }')"
    check_info "автоперезагрузка: ${v:-false}"
    [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]] && check_info "последний запуск: $(tail -1 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | cut -c1-19)"
    return 0
}
