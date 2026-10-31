# shellcheck shell=bash
MOD_SUMMARY='sysctl: сетевой hardening ядра (CIS L1) и производительность сети/ФС'
MOD_GROUP=system
MOD_DEFAULT=1
MOD_DEPS=(preflight)

SYSCTL_HARD='/etc/sysctl.d/90-ubuntu-bootstrap-hardening.conf'
SYSCTL_PERF='/etc/sysctl.d/91-ubuntu-bootstrap-performance.conf'

mod_options() {
    opt SYSCTL_HARDENING bool yes 'Сетевой hardening (syncookies, rp_filter, без redirects/source routing, лог martians)'
    opt SYSCTL_PERFORMANCE bool yes 'Производительность: очереди соединений, диапазон портов, буферы, inotify, file-max'
    opt SYSCTL_BBR bool yes 'TCP BBR + fq (лучше пропускная способность и задержки на потерях)'
    opt SYSCTL_IP_FORWARD enum:auto,on,off auto 'ip_forward: auto — выключить, если нет Docker/WireGuard' adv
    opt SYSCTL_IPV6 enum:keep,disable keep 'IPv6: keep — не трогать, disable — отключить' adv
}

sysctl_forward_wanted() {
    case $(cfg SYSCTL_IP_FORWARD) in
        on) return 0 ;;
        off) return 1 ;;
        *) module_enabled docker || has_cmd docker || has_cmd wg || [[ -d /etc/wireguard ]] ;;
    esac
}

sysctl_hard_render() {
    cat <<'EOT'
# ubuntu-bootstrap: network hardening (CIS Ubuntu Benchmark L1, Network Parameters).
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
# Filesystem and kernel
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
kernel.kptr_restrict = 1
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
EOT
    if sysctl_forward_wanted; then
        printf '# ip_forward is needed by Docker/WireGuard and is left enabled\n'
    else
        printf 'net.ipv4.ip_forward = 0\nnet.ipv6.conf.all.forwarding = 0\n'
    fi
    [[ $(cfg SYSCTL_IPV6) == disable ]] && printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n'
    return 0
}

sysctl_perf_render() {
    cat <<'EOT'
# ubuntu-bootstrap: performance for nginx/Docker/databases. Moderate values: extreme ones hide leaks.
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.aio-max-nr = 1048576
vm.max_map_count = 262144
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
EOT
    if sysctl_bbr_wanted; then
        printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n'
    fi
}

sysctl_bbr_available() {
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || modinfo -n tcp_bbr >/dev/null 2>&1
}

# BBR goes into the rendered file only when this kernel can provide it, so the module stays idempotent.
sysctl_bbr_wanted() {
    cfg_bool SYSCTL_BBR && ((F_CONTAINER == 0)) && sysctl_bbr_available
}

sysctl_apply_file() {
    local f=$1 bad
    ((DRY_RUN)) && return 0
    # Some keys are read-only inside containers; per-key failures are not fatal, the file applies at boot.
    bad="$(sysctl -q -e -p "$f" 2>&1 | grep -v '^$' || true)"
    [[ -n $bad ]] && log_warn "sysctl: не применились на лету: $(printf '%s' "$bad" | head -3 | tr '\n' ';')"
    return 0
}

mod_check() {
    if cfg_bool SYSCTL_HARDENING; then [[ -f $SYSCTL_HARD && $(cat "$SYSCTL_HARD") == "$(sysctl_hard_render)" ]] || return 1; fi
    if cfg_bool SYSCTL_PERFORMANCE; then [[ -f $SYSCTL_PERF && $(cat "$SYSCTL_PERF") == "$(sysctl_perf_render)" ]] || return 1; fi
    ((F_CONTAINER)) && return 0
    cfg_bool SYSCTL_HARDENING && [[ $(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null) != 1 ]] && return 1
    sysctl_bbr_wanted && [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) != bbr ]] && return 1
    return 0
}

mod_apply() {
    if cfg_bool SYSCTL_HARDENING; then
        undo sysctl --system
        sysctl_hard_render | file_write "$SYSCTL_HARD" 644
        [[ ${FILE_CHANGED:-0} == 1 ]] && sysctl_apply_file "$SYSCTL_HARD"
    elif [[ -f $SYSCTL_HARD ]]; then
        file_remove "$SYSCTL_HARD"
    fi
    if cfg_bool SYSCTL_PERFORMANCE; then
        if sysctl_bbr_wanted; then
            grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || run modprobe tcp_bbr || return 1
            printf 'tcp_bbr\n' | file_write /etc/modules-load.d/ubuntu-bootstrap-bbr.conf 644
        elif cfg_bool SYSCTL_BBR && ((F_CONTAINER == 0)); then
            log_warn 'модуль tcp_bbr недоступен в этом ядре — BBR пропущен'
        fi
        undo sysctl --system
        sysctl_perf_render | file_write "$SYSCTL_PERF" 644
        [[ ${FILE_CHANGED:-0} == 1 ]] && sysctl_apply_file "$SYSCTL_PERF"
    elif [[ -f $SYSCTL_PERF ]]; then
        file_remove "$SYSCTL_PERF"
    fi
    ((DRY_RUN)) || ((F_CONTAINER)) || log_ok "sysctl: tcp_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null) ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    return 0
}

mod_verify() { ((DRY_RUN)) || mod_check; }

mod_audit() {
    ((F_CONTAINER)) && { check_info 'контейнер: sysctl ядра принадлежит хосту'; return 0; }
    local k v
    for k in net.ipv4.tcp_syncookies=1 net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.all.send_redirects=0 fs.protected_symlinks=1 kernel.dmesg_restrict=1; do
        v="$(sysctl -n "${k%=*}" 2>/dev/null)"
        [[ $v == "${k#*=}" ]] && check_ok "$k" || check_warn "${k%=*}=${v:-?} (ожидалось ${k#*=})"
    done
    v="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    if [[ $v == 1 ]]; then
        has_cmd docker || has_cmd wg && check_info 'ip_forward=1 (нужен Docker/WireGuard)' || check_warn 'ip_forward=1 без Docker/WireGuard'
    else
        check_ok 'ip_forward=0'
    fi
    check_info "tcp_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null), somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null)"
}
