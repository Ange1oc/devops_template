# shellcheck shell=bash
MOD_SUMMARY='синхронизация времени (chrony или systemd-timesyncd)'
MOD_GROUP=system
MOD_DEFAULT=1
MOD_DEPS=(preflight)

mod_options() {
    opt TIME_DAEMON enum:auto,chrony,timesyncd auto 'Служба NTP: auto — оставить имеющуюся (26.04 ставит chrony с NTS, старше — timesyncd)'
    opt TIME_SERVERS list '' 'NTP-серверы (пусто — умолчания дистрибутива/провайдера)' adv
}

time_daemon_current() {
    if pkg_installed chrony; then printf chrony; elif pkg_installed systemd-timesyncd || svc_exists systemd-timesyncd.service; then printf timesyncd; fi
}

time_daemon_target() {
    local t
    t="$(cfg TIME_DAEMON)"
    [[ $t == auto ]] && { t="$(time_daemon_current)"; t=${t:-timesyncd}; }
    printf '%s' "$t"
}

time_unit() { [[ $1 == chrony ]] && printf chrony.service || printf systemd-timesyncd.service; }

# systemd-timesyncd and chrony carry ConditionVirtualization=!container: the host owns the clock.
time_skip() { ((F_CONTAINER)); }

mod_check() {
    local t
    time_skip && return 0
    t="$(time_daemon_target)"
    [[ $(time_daemon_current) == "$t" ]] || return 1
    svc_active "$(time_unit "$t")" && [[ $(timedatectl show -p NTP --value 2>/dev/null) == yes ]]
}

mod_apply() {
    local t servers s
    local -a list=()
    t="$(time_daemon_target)"
    time_skip && { log_warn 'контейнер: время задаёт хост, служба NTP не запускается'; return 0; }
    case $t in
        chrony)
            # chrony conflicts with systemd-timesyncd and replaces it on install.
            apt_install chrony || return 1
            cfg_list TIME_SERVERS list
            if ((${#list[@]})); then
                servers=''
                for s in "${list[@]}"; do servers+="server $s iburst"$'\n'; done
                printf '%s' "$servers" | file_write /etc/chrony/sources.d/ubuntu-bootstrap.sources 644
                [[ ${FILE_CHANGED:-0} == 1 ]] && undo systemctl restart chrony && run systemctl restart chrony
            fi
            ;;
        timesyncd)
            pkg_installed systemd-timesyncd || apt_install systemd-timesyncd || return 1
            cfg_list TIME_SERVERS list
            if ((${#list[@]})); then
                printf '[Time]\nNTP=%s\n' "${list[*]}" | file_write /etc/systemd/timesyncd.conf.d/ubuntu-bootstrap.conf 644
                [[ ${FILE_CHANGED:-0} == 1 ]] && undo systemctl restart systemd-timesyncd && run systemctl restart systemd-timesyncd
            fi
            ;;
    esac
    svc_enable_now "$(time_unit "$t")" || return 1
    run timedatectl set-ntp true || true
    log_ok "служба времени: $t"
    return 0
}

mod_verify() { mod_check; }

mod_audit() {
    local synced
    time_skip && { check_info 'контейнер: время от хоста'; return 0; }
    synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    [[ $synced == yes ]] && check_ok "время синхронизировано ($(time_daemon_current))" || check_warn 'время не синхронизировано по NTP' 'timedatectl timesync-status / chronyc tracking'
}
