# shellcheck shell=bash
MOD_SUMMARY='UFW: deny по умолчанию, SSH с rate-limit, web-порты, защита от обхода Docker'
MOD_GROUP=security
MOD_DEFAULT=1
MOD_DEPS=(preflight)
MOD_AFTER=(ssh docker)

UFW_AFTER_RULES='/etc/ufw/after.rules'
UFW_AFTER6_RULES='/etc/ufw/after6.rules'
UFW_DOCKER_MARKER='ubuntu-bootstrap docker'

mod_options() {
    opt FW_SSH_LIMIT bool yes 'SSH через ufw limit (6 подключений за 30 с с одного IP)'
    opt FW_SSH_FROM cidrs '' 'Разрешить SSH только с этих IP/CIDR (пусто — откуда угодно)'
    opt FW_WEB enum:auto,yes,no auto 'Открыть 80/443 (auto — если включён модуль nginx или nginx установлен)'
    opt FW_HTTP3 bool yes 'Открыть 443/udp (HTTP/3)' adv
    opt FW_ALLOW_PORTS ports '' 'Дополнительно открыть порты, напр. 8443/tcp,51820/udp'
    opt FW_DOCKER_PROTECT enum:auto,yes,no auto 'Блокировать внешний доступ к контейнерам (DOCKER-USER), auto — если есть Docker'
    opt FW_DOCKER_ALLOW_PORTS ports '' 'Порты контейнеров, доступные снаружи несмотря на защиту' adv
    opt FW_LOGGING enum:off,low,medium low 'Логирование UFW' adv
    opt FW_CONFIRM enum:auto,wait,none auto 'Подтверждение доступа после включения (как у ssh; none — только с --force)' adv
    opt FW_CONFIRM_TIMEOUT int 180 'Секунд до автоматического отката' adv
}

mod_wizard() {
    log_plain '  Docker публикует порты в обход UFW (docs.docker.com: «Docker and ufw are incompatible»).'
    log_plain '  Защита DOCKER-USER закрывает контейнеры снаружи; наружу должен смотреть только nginx (80/443).'
}

fw_want_web() {
    case $(cfg FW_WEB) in
        yes) return 0 ;;
        no) return 1 ;;
        *) module_enabled nginx || has_cmd nginx ;;
    esac
}

fw_want_docker() {
    case $(cfg FW_DOCKER_PROTECT) in
        yes) return 0 ;;
        no) return 1 ;;
        *) module_enabled docker || has_cmd docker ;;
    esac
}

# Inside a container UFW works only with NET_ADMIN.
fw_available() { ((F_CONTAINER == 0)) || iptables -L -n >/dev/null 2>&1; }

fw_ssh_ports() {
    local p
    p="$(sshd_effective_ports)"
    if module_enabled ssh && [[ $(cfg SSH_PORT) != keep ]]; then p="$(cfg SSH_PORT)"; fi
    printf '%s' "$p"
}

# Desired rules, one per line: "allow|limit PORT/PROTO [from CIDR]".
fw_rules() {
    local p action
    local -a from=() extra=()
    cfg_bool FW_SSH_LIMIT && action=limit || action=allow
    cfg_list FW_SSH_FROM from
    for p in $(fw_ssh_ports); do
        if ((${#from[@]})); then
            local c
            for c in "${from[@]}"; do printf 'allow %s/tcp from %s\n' "$p" "$c"; done
        else
            printf '%s %s/tcp\n' "$action" "$p"
        fi
    done
    if fw_want_web; then
        printf 'allow 80/tcp\nallow 443/tcp\n'
        cfg_bool FW_HTTP3 && printf 'allow 443/udp\n'
    fi
    cfg_list FW_ALLOW_PORTS extra
    for p in "${extra[@]}"; do
        [[ $p == */* ]] && printf 'allow %s\n' "$p" || printf 'allow %s/tcp\n' "$p"
    done
}

# ufw status prints "PORT/proto[ (v6)]  ACTION  FROM".
ufw_has_rule() {
    local port=$1 action=${2^^} src=${3:-Anywhere}
    ufw status 2>/dev/null | awk -v p="$port" -v a="$action" -v f="$src" '
        $1 == p && $2 ~ a && (f == "Anywhere" ? $3 ~ /^Anywhere$/ : $3 == f) { found = 1 } END { exit !found }'
}

# ufw rewrites its files in ASCII, so this block must stay ASCII-only.
fw_docker_block() {
    local i p proto
    local -a ifaces=() allow=()
    [[ -n $F_DEFAULT_IFACE ]] && ifaces=("$F_DEFAULT_IFACE")
    ((${#ifaces[@]})) || return 0
    cfg_list FW_DOCKER_ALLOW_PORTS allow
    cat <<EOT
# Docker bypasses UFW INPUT chains (rules live in FORWARD/nat). DOCKER-USER is evaluated first:
# new connections from the external interface to containers are dropped except explicitly allowed
# ports (matched by original destination port, before DNAT). Containers stay reachable from
# localhost and docker networks.
*filter
:DOCKER-USER - [0:0]
EOT
    for i in "${ifaces[@]}"; do
        printf -- '-A DOCKER-USER -i %s -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN\n' "$i"
        for p in "${allow[@]}"; do
            proto=tcp
            [[ $p == */* ]] && { proto=${p#*/}; p=${p%/*}; }
            printf -- '-A DOCKER-USER -i %s -p %s -m conntrack --ctstate NEW --ctorigdstport %s --ctdir ORIGINAL -j RETURN\n' "$i" "$proto" "$p"
        done
        printf -- '-A DOCKER-USER -i %s -m conntrack --ctstate NEW -j DROP\n' "$i"
    done
    printf -- '-A DOCKER-USER -j RETURN\nCOMMIT\n'
}

mod_check() {
    local action port from rest
    ufw_active || return 1
    while read -r action port rest; do
        from=${rest#from }
        [[ $rest == from* ]] || from=Anywhere
        ufw_has_rule "$port" "$action" "$from" || return 1
    done < <(fw_rules)
    if fw_want_docker; then grep -q "BEGIN $UFW_DOCKER_MARKER" "$UFW_AFTER_RULES" 2>/dev/null || return 1
    else ! grep -q "BEGIN $UFW_DOCKER_MARKER" "$UFW_AFTER_RULES" 2>/dev/null || return 1; fi
    return 0
}

# Undo command: after the rule files are restored, return UFW to its previous enabled state.
fw_restore() {
    if [[ $1 == active ]]; then ufw reload; else ufw --force disable; fi
}

fw_selfcheck() {
    local p
    ufw_active || return 1
    for p in $(fw_ssh_ports); do ufw status | grep -Eq "^$p(/tcp)?[[:space:]]" || return 1; done
    return 0
}

# a.b.c.d/len contains ip (IPv4).
cidr_contains4() {
    local net=${1%/*} len=${1#*/} ip=$2 n i m
    local -a a=() b=()
    is_ipv4 "$net" && is_ipv4 "$ip" || return 1
    IFS=. read -r -a a <<< "$net"
    IFS=. read -r -a b <<< "$ip"
    n=$(((a[0] << 24) | (a[1] << 16) | (a[2] << 8) | a[3]))
    i=$(((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]))
    ((len == 0)) && return 0
    m=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF))
    (((n & m) == (i & m)))
}

mod_apply() {
    local was action port rest from f changed=0
    local -a from_list=()
    apt_install ufw || return 1
    fw_available || { log_warn 'контейнер без NET_ADMIN: UFW недоступен'; return 0; }

    # Guards and confirmations first: the current session must not be locked out by FW_SSH_FROM.
    cfg_list FW_SSH_FROM from_list
    if ((${#from_list[@]})) && [[ -n $F_SSH_CLIENT_IP ]]; then
        local ok=0 c
        for c in "${from_list[@]}"; do
            if [[ $c == */* ]]; then cidr_contains4 "$c" "$F_SSH_CLIENT_IP" && ok=1; else [[ $c == "$F_SSH_CLIENT_IP" ]] && ok=1; fi
        done
        ((ok)) || { guard_refuse "FW_SSH_FROM не включает IP текущей сессии $F_SSH_CLIENT_IP" || return; }
    fi
    ufw_active && was=active || was=inactive
    if [[ $was == inactive ]]; then
        confirm_danger "UFW будет включён: входящие соединения запрещены, кроме $(fw_rules | awk '{ printf "%s ", $2 }')" || return "$E_REFUSED"
        if [[ -n $F_SSH_CLIENT_IP && $(cfg FW_CONFIRM) == none ]]; then
            guard_refuse 'FW_CONFIRM=none: UFW включится без таймера отката' || return
        fi
    fi

    undo fw_restore "$was"
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules /etc/ufw/ufw.conf "$UFW_AFTER_RULES" "$UFW_AFTER6_RULES"; do file_snapshot "$f"; done

    [[ $was == active ]] && log_info 'UFW уже активен — дополняю правила'
    run ufw default deny incoming || return 1
    run ufw default allow outgoing || return 1
    run ufw logging "$(cfg FW_LOGGING)" || return 1
    while read -r action port rest; do
        from=Anywhere
        [[ $rest == from* ]] && from=${rest#from }
        ufw_has_rule "$port" "$action" "$from" && continue
        changed=1
        local tag=ubuntu-bootstrap
        [[ " $(fw_ssh_ports) " == *" ${port%/*} "* ]] && tag='SSH (ubuntu-bootstrap)'
        if [[ $from == Anywhere ]]; then
            run ufw "$action" "$port" comment "$tag" || return 1
        else
            run ufw allow from "$from" to any port "${port%/*}" proto "${port#*/}" comment "$tag" || return 1
        fi
        log_ok "правило: $action $port${rest:+ $rest}"
    done < <(fw_rules)

    if fw_want_docker; then
        fw_docker_block | file_set_block "$UFW_AFTER_RULES" "$UFW_DOCKER_MARKER" 640
        [[ ${FILE_CHANGED:-0} == 1 ]] && changed=1 && log_ok 'защита DOCKER-USER добавлена в after.rules'
    else
        file_set_block "$UFW_AFTER_RULES" "$UFW_DOCKER_MARKER" 640 < /dev/null
        [[ ${FILE_CHANGED:-0} == 1 ]] && changed=1
    fi
    ((DRY_RUN)) && return 0

    if [[ $was == active ]]; then
        ((changed)) && { run ufw reload || return 1; }
        log_ok 'UFW активен, правила обновлены'
        return 0
    fi
    run ufw --force enable || return 1
    ufw status verbose | sed 's/^/    /' >&2
    [[ -n $F_SSH_CLIENT_IP ]] || { log_ok 'UFW включён (локальная консоль, подтверждение не требуется)'; return 0; }
    confirm_or_rollback firewall "$(cfg FW_CONFIRM_TIMEOUT)" "$(cfg FW_CONFIRM)" 'SSH-доступ в новой сессии работает?' fw_selfcheck
}

mod_verify() { ((DRY_RUN)) || ! fw_available || mod_check; }

mod_audit() {
    local p
    if ! has_cmd ufw; then check_fail 'UFW не установлен'; return 0; fi
    ufw_active && check_ok 'UFW активен' || { check_fail 'UFW не активен'; return 0; }
    ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming)' && check_ok 'входящие по умолчанию запрещены' || check_fail 'политика по умолчанию не deny incoming'
    for p in $(sshd_effective_ports); do
        ufw status 2>/dev/null | grep -Eq "^$p(/tcp)?[[:space:]]" && check_ok "SSH-порт $p разрешён в UFW" || check_fail "SSH-порт $p не разрешён в UFW"
    done
    if has_cmd docker; then
        grep -q "BEGIN $UFW_DOCKER_MARKER" "$UFW_AFTER_RULES" 2>/dev/null && check_ok 'DOCKER-USER защищает контейнеры от внешнего доступа' ||
            check_warn 'Docker установлен, но защита DOCKER-USER не настроена: опубликованные порты доступны снаружи в обход UFW'
    fi
    check_info "правил UFW: $(ufw status 2>/dev/null | grep -cE '^[0-9]')"
}
