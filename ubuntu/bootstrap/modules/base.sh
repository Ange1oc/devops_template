# shellcheck shell=bash
MOD_SUMMARY='базовые пакеты, обновление системы, hostname, timezone'
MOD_GROUP=system
MOD_DEFAULT=1
MOD_DEPS=(preflight)

BASE_PKGS_DEFAULT='ca-certificates,curl,gnupg,git,jq,rsync,unzip,htop,ncdu,bind9-dnsutils,openssl,needrestart,logrotate'

mod_options() {
    opt BASE_UPGRADE bool yes 'Обновить установленные пакеты (apt-get upgrade)'
    opt BASE_PACKAGES list "$BASE_PKGS_DEFAULT" 'Базовые пакеты' adv
    opt BASE_EXTRA_PACKAGES list '' 'Дополнительные пакеты'
    opt BASE_TIMEZONE timezone '' 'Часовой пояс (пусто — не менять, напр. UTC или Europe/Moscow)'
    opt BASE_HOSTNAME hostname '' 'Имя хоста (пусто — не менять)'
    opt BASE_AUTOREMOVE bool yes 'Удалять ненужные пакеты (autoremove)' adv
}

base_packages() {
    local -a a=() b=()
    cfg_list BASE_PACKAGES a
    cfg_list BASE_EXTRA_PACKAGES b
    printf '%s\n' "${a[@]}" "${b[@]}"
}

mod_check() {
    local p
    for p in $(base_packages); do pkg_installed "$p" || return 1; done
    [[ -z $(cfg BASE_TIMEZONE) || $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null) == "$(cfg BASE_TIMEZONE)" ]] || return 1
    [[ -z $(cfg BASE_HOSTNAME) || $(hostname) == "$(cfg BASE_HOSTNAME)" ]] || return 1
    return 0
}

mod_apply() {
    local tz cur_tz host
    local -a pkgs=()
    mapfile -t pkgs < <(base_packages)
    if cfg_bool BASE_UPGRADE; then
        log_info 'apt-get update && upgrade'
        if cfg_bool BASE_AUTOREMOVE; then apt_upgrade --autoremove || return 1; else apt_upgrade || return 1; fi
    fi
    apt_install "${pkgs[@]}" || return 1

    tz="$(cfg BASE_TIMEZONE)"
    cur_tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
    if [[ -n $tz && $cur_tz != "$tz" ]]; then
        [[ -n $cur_tz ]] && undo timedatectl set-timezone "$cur_tz"
        if ((F_HAS_SYSTEMD)); then run timedatectl set-timezone "$tz" || return 1; else
            run ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime && printf '%s\n' "$tz" | file_write /etc/timezone 644
        fi
        log_ok "часовой пояс: $tz"
    fi

    host="$(cfg BASE_HOSTNAME)"
    if [[ -n $host && $(hostname) != "$host" ]]; then
        undo hostnamectl set-hostname "$(hostname)"
        if ((F_HAS_SYSTEMD)); then run hostnamectl set-hostname "$host" || return 1; else printf '%s\n' "$host" | file_write /etc/hostname 644 && run hostname "$host"; fi
        # sudo complains when the hostname does not resolve; keep an /etc/hosts entry.
        file_set_block /etc/hosts 'ubuntu-bootstrap hostname' <<< "127.0.1.1 $host ${host%%.*}"
        log_ok "hostname: $host"
    fi
    [[ -f /var/run/reboot-required ]] && log_warn 'после обновления требуется перезагрузка — выполни её после завершения настройки'
    return 0
}

mod_verify() { mod_check; }

mod_audit() {
    local p missing=''
    for p in $(base_packages); do pkg_installed "$p" || missing+="$p "; done
    [[ -z $missing ]] && check_ok 'базовые пакеты установлены' || check_warn "не установлены: $missing"
    local hn
    hn="$(hostname)"
    getent hosts "$hn" >/dev/null 2>&1 && check_ok "hostname $hn резолвится" || check_warn "hostname $hn не резолвится (sudo будет ругаться)" 'запись в /etc/hosts'
}
