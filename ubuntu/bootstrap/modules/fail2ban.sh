# shellcheck shell=bash
MOD_SUMMARY='fail2ban: бан IP после неудачных SSH-входов (журнал systemd)'
MOD_GROUP=security
MOD_DEFAULT=1
MOD_DEPS=(preflight)
MOD_AFTER=(ssh firewall)

F2B_JAIL='/etc/fail2ban/jail.d/ubuntu-bootstrap.local'

mod_options() {
    opt F2B_MAXRETRY int 5 'Неудачных попыток до бана'
    opt F2B_FINDTIME duration 10m 'Окно подсчёта попыток'
    opt F2B_BANTIME duration 1h 'Длительность бана'
    opt F2B_INCREMENT bool yes 'Увеличивать бан повторным нарушителям (до 1 недели)' adv
    opt F2B_IGNOREIP cidrs '' 'Никогда не банить эти IP/CIDR'
    opt F2B_IGNORE_CURRENT bool yes 'Добавить IP текущей SSH-сессии в ignoreip' adv
}

f2b_ignore_list() {
    local -a list=()
    cfg_list F2B_IGNOREIP list
    cfg_bool F2B_IGNORE_CURRENT && [[ -n $F_SSH_CLIENT_IP ]] && ! in_list "$F_SSH_CLIENT_IP" "${list[@]}" && list+=("$F_SSH_CLIENT_IP")
    printf '127.0.0.1/8 ::1 %s' "${list[*]}"
}

f2b_render() {
    cat <<EOT
# ubuntu-bootstrap. Reads the systemd journal: auth.log may be absent on Ubuntu 24.04+.
# journalmatch covers the ssh.service unit (Ubuntu) and the sshd/sshd-session processes (OpenSSH 9.8+).
[DEFAULT]
ignoreip = $(f2b_ignore_list)
bantime = $(cfg F2B_BANTIME)
findtime = $(cfg F2B_FINDTIME)
maxretry = $(cfg F2B_MAXRETRY)
bantime.increment = $(cfg_bool F2B_INCREMENT && echo true || echo false)
bantime.maxtime = 1w

[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
port = $(sshd_effective_ports | tr ' ' ',')
mode = aggressive
EOT
}

mod_check() {
    pkg_installed fail2ban && pkg_installed python3-systemd && [[ -f $F2B_JAIL && $(cat "$F2B_JAIL") == "$(f2b_render)" ]] && svc_active fail2ban
}

mod_apply() {
    local was_active=0 i
    # python3-systemd is only Recommends on 22.04 and we install without recommends.
    apt_install fail2ban python3-systemd || return 1
    svc_active fail2ban && was_active=1
    undo systemctl reload-or-restart fail2ban
    f2b_render | file_write "$F2B_JAIL" 644
    ((DRY_RUN)) && return 0
    if ! fail2ban-client -t >> "$LOG_FILE" 2>&1; then
        log_error "fail2ban-client -t: конфигурация невалидна: $(fail2ban-client -t 2>&1 | tail -3)"
        return 1
    fi
    # A freshly started service reads the file itself; reload only an already running one, and
    # only once it answers (reload right after start fails).
    svc_enable_now fail2ban || return 1
    for i in $(seq 1 20); do fail2ban-client ping >/dev/null 2>&1 && break; sleep 1; done
    if ((was_active)) && [[ ${FILE_CHANGED:-0} == 1 ]]; then
        run systemctl reload fail2ban || { sleep 3; run systemctl reload fail2ban || return 1; }
    fi
    for i in $(seq 1 15); do fail2ban-client status sshd >/dev/null 2>&1 && break; sleep 1; done
    fail2ban-client status sshd >> "$LOG_FILE" 2>&1 || { log_error "jail sshd не поднялся: $(journalctl -u fail2ban -n 5 --no-pager 2>/dev/null | tail -3)"; return 1; }
    log_ok "fail2ban активен: jail sshd, порты $(sshd_effective_ports), ignoreip $(f2b_ignore_list)"
    return 0
}

mod_verify() { ((DRY_RUN)) || mod_check; }

mod_audit() {
    local st jp
    has_cmd fail2ban-client || { check_warn 'fail2ban не установлен'; return 0; }
    svc_active fail2ban && check_ok 'fail2ban активен' || { check_fail 'fail2ban не активен'; return 0; }
    st="$(fail2ban-client status sshd 2>/dev/null)" || { check_fail 'jail sshd не активен'; return 0; }
    check_ok "jail sshd: забанено сейчас $(awk -F: '/Currently banned/ { gsub(/ /, "", $2); print $2 }' <<< "$st"), всего $(awk -F: '/Total banned/ { gsub(/ /, "", $2); print $2 }' <<< "$st")"
    jp="$(grep -E '^port' "$F2B_JAIL" 2>/dev/null | awk -F'= ' '{ print $2 }')"
    [[ -n $jp && $jp != "$(sshd_effective_ports | tr ' ' ',')" ]] && check_warn "порт в jail ($jp) отличается от sshd ($(sshd_effective_ports))" 'ubuntu-bootstrap apply --only fail2ban --reapply'
    return 0
}
