# shellcheck shell=bash
# Guards: protection of SSH access, existing VPNs and foreign configs.
#
# Levels: 0 safe; 1 needs an explicit confirmation (typed word or --yes) and arms the rollback
# timer; 2 blocked unless --force is given.

guard_raise() {
    local level=$1
    shift
    ((level > GUARD_LEVEL)) && GUARD_LEVEL=$level
    GUARD_MSGS+=("$*")
}

# canon_owner_of_ip CANON IP: public key of the peer whose AllowedIPs contain IP.
canon_owner_of_ip() {
    local canon=$1 ip=$2 t pk k v c
    local -a list=()
    while IFS=$FS read -r t pk k v; do
        [[ $t == P && $k == allowedips ]] || continue
        split_csv "$v" list
        for c in "${list[@]}"; do
            cidr_contains "$c" "$ip" && { printf '%s' "$pk"; return 0; }
        done
    done < "$canon"
    return 1
}

canon_name_of() {
    local name
    name="$(awk -F "$FS" -v pk="$2" '$1 == "N" && $2 == pk { print $3; exit }' "${PLAN_NAMES:-/dev/null}")"
    printf '%s' "${name:-${2:0:8}…}"
}

# guard_check OLD_CANON NEW_CANON CLASS: sets GUARD_LEVEL and GUARD_MSGS.
guard_check() {
    local old=$1 new=$2 class=$3 client server addr c len best owner_old owner_new
    local -a addrs=() added=() new_list=() old_list=()
    GUARD_LEVEL=0
    GUARD_MSGS=()
    [[ $class == none || $class == rewrite ]] && return 0

    mapfile -t addrs < <(iface_addresses "$IFACE")
    mapfile -t new_list < <(canon_allowed_ips "$new")
    mapfile -t old_list < <(canon_allowed_ips "$old")
    for c in "${new_list[@]}"; do
        [[ " ${old_list[*]} " == *" $c "* ]] || added+=("$c")
    done
    # On start, routes may already exist without being in the old config (manual wg-quick up).
    [[ $class == start ]] && added=("${new_list[@]}")

    while read -r client server; do
        [[ -n $client ]] || continue
        # A session depends on the interface if it targets an interface address or if replies
        # leave through it (a client behind a peer connected to a public address).
        local via=0
        for addr in "${addrs[@]}"; do
            [[ $(ip_normalize "$addr") == "$(ip_normalize "$server")" ]] && via=1
        done
        if ((!via)) && [[ " $(ip route get "$client" 2>/dev/null) " == *" dev $IFACE "* ]]; then
            via=1
        fi

        if ((via)); then
            if [[ $class == restart ]]; then
                guard_raise 1 "SSH-сессия $client → $server идёт через $IFACE: при перезапуске связь пропадёт на 1–3 с (TCP обычно переживает)"
            elif [[ $class == hot ]]; then
                owner_old="$(canon_owner_of_ip "$old" "$client" || true)"
                owner_new="$(canon_owner_of_ip "$new" "$client" || true)"
                if [[ -n $owner_old && $owner_old != "$owner_new" ]]; then
                    guard_raise 2 "SSH-сессия от $client идёт через peer $(canon_name_of "$old" "$owner_old"), который удаляется или меняется: доступ будет потерян"
                fi
            fi
            continue
        fi

        [[ ${NODE[TABLE]} == auto ]] || continue
        for c in "${added[@]}"; do
            cidr_contains "$c" "$client" || continue
            len=${c##*/}
            best="$(best_route_prefix "$client")"
            # wg-quick installs /0 in its own table with suppress_prefixlength 0: only traffic
            # that currently follows the default route is captured.
            if ((len > best)) || ((len == 0 && best <= 0)); then
                guard_raise 2 "маршрут $c уведёт в туннель трафик к SSH-клиенту $client: доступ по SSH будет потерян"
            fi
        done
    done < <(ssh_sessions)
    return 0
}

guard_report() {
    local msg
    ((${#GUARD_MSGS[@]})) || return 0
    log_title 'Предупреждения безопасности'
    for msg in "${GUARD_MSGS[@]}"; do
        log_warn "$msg"
    done
}

# Before init: never take over a foreign VPN, a busy port or an overlapping network.
guard_init_target() {
    local force=$1 port=${2-} cidr=${3-} conflicts
    if ! st_exists; then
        if [[ -f $LIVE_CONF ]]; then
            ((force)) || die_code "$E_REFUSED" "$LIVE_CONF уже существует и не создан wg-network. Это может быть рабочий VPN: выбери другой интерфейс (-i wg1) или используй --force (файл уйдёт в бэкап)"
            log_warn "$LIVE_CONF не управляется wg-network и будет заменён (бэкап сохраняется)"
        fi
        if iface_exists "$IFACE"; then
            ((force)) || die_code "$E_REFUSED" "интерфейс $IFACE уже существует и не управляется wg-network. Выбери другое имя (-i) или --force"
        fi
    fi
    if [[ -n $port ]] && port_in_use_udp "$port" && ! { iface_running && [[ $(wg show "$IFACE" listen-port 2>/dev/null) == "$port" ]]; }; then
        die_code "$E_REFUSED" "UDP-порт $port уже занят (ss -ulpn 'sport = :$port'). Укажи другой --port"
    fi
    if [[ -n $cidr ]]; then
        local net
        cidr_network "$cidr" net
        conflicts="$(local_route_conflicts "$net")"
        if [[ -n $conflicts ]]; then
            log_warn "сеть $net пересекается с существующими маршрутами:"
            printf '    %s\n' "$conflicts" >&2
            ((force)) || die_code "$E_REFUSED" "выбери другую сеть (--address) или --force, если понимаешь последствия"
        fi
    fi
}

# Routes behind a peer must not shadow local networks of this server (LAN, Docker, other VPNs).
guard_route_conflicts() {
    local force=$1 c conflicts
    local -a routes=()
    split_csv "$2" routes
    for c in "${routes[@]}"; do
        [[ ${c##*/} == 0 ]] && continue
        conflicts="$(local_route_conflicts "$c")"
        [[ -n $conflicts ]] || continue
        log_warn "маршрут $c пересекается с локальными маршрутами сервера:"
        printf '    %s\n' "$conflicts" >&2
        ((force)) || die_code "$E_REFUSED" "используй --force, если это намеренно"
    done
}
