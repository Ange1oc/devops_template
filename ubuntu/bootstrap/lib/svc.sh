# shellcheck shell=bash
# systemd units, drop-ins and safe sshd reconfiguration.

svc_exists() {
    ((F_HAS_SYSTEMD)) || return 1
    [[ -n $(systemctl list-unit-files --no-legend "$1" 2>/dev/null) ]] || systemctl cat "$1" >/dev/null 2>&1
}

svc_active()  { ((F_HAS_SYSTEMD)) && systemctl is-active --quiet "$1" 2>/dev/null; }
svc_enabled() { ((F_HAS_SYSTEMD)) && [[ $(systemctl is-enabled "$1" 2>/dev/null) == enabled ]]; }

svc_enable_now() {
    ((F_HAS_SYSTEMD)) || { log_warn "нет systemd: $1 не запущен"; return 0; }
    svc_enabled "$1" && svc_active "$1" && return 0
    run systemctl enable --now "$1"
}

svc_daemon_reload() { run systemctl daemon-reload; }

# svc_dropin UNIT NAME: drop-in from stdin, daemon-reload when it changed.
svc_dropin() {
    local unit=$1 name=$2 dir="/etc/systemd/system/$1.d"
    file_write "$dir/$name.conf" 644
    [[ ${FILE_CHANGED:-0} == 1 ]] && svc_daemon_reload
    return 0
}

# Apply sshd configuration. Since Ubuntu 22.10 sshd is socket-activated: the generator reads ports
# at daemon-reload, so a port change needs `restart ssh.socket`, not a service reload (LP#2069041).
# Existing sessions survive the restart (KillMode=process).
sshd_apply() {
    local old_ports=$1 new_ports p
    sshd_ready
    if ! sshd -t >> "${LOG_FILE:-/dev/null}" 2>&1; then
        log_error "sshd -t: конфиг невалиден: $(sshd -t 2>&1 | head -3)"
        return 1
    fi
    ((DRY_RUN)) && { log_info '[dry-run] применение конфига sshd'; return 0; }
    ((F_HAS_SYSTEMD)) || { run sshd -t && run pkill -HUP -x sshd; return; }
    new_ports="$(sshd_effective_ports)"
    if sshd_socket_activated && [[ $old_ports != "$new_ports" ]]; then
        run systemctl daemon-reload || return 1
        run systemctl restart ssh.socket || return 1
        svc_active ssh.service && run systemctl restart ssh.service
    else
        run systemctl reload-or-restart ssh.service || return 1
    fi
    sleep 1
    for p in $new_ports; do
        port_listening "$p" || { log_error "sshd не слушает порт $p после применения"; return 1; }
    done
}
