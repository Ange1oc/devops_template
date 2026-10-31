# shellcheck shell=bash
# System interaction: packages, keys, systemd, the interface, routes, firewall, SSH sessions.

has_systemd() {
    [[ -d /run/systemd/system ]] && has_cmd systemctl
}

sys_install_wireguard() {
    has_cmd wg && has_cmd wg-quick && return 0
    ((OPT_DRY_RUN)) && die 'для --dry-run нужен установленный wireguard-tools'
    has_cmd apt-get || die 'wireguard-tools не установлен, а apt-get не найден: установи пакет вручную'
    log_info 'Устанавливаю wireguard-tools'
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends wireguard-tools >/dev/null
}

sys_ensure_key() {
    [[ -s $ST_KEY ]] && return 0
    (umask 077 && wg genkey) | write_atomic "$ST_KEY" 600
}

node_public_key() {
    wg pubkey < "$ST_KEY"
}

iface_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

unit_active() {
    has_systemd || return 1
    systemctl is-active --quiet "$UNIT"
}

unit_enabled() {
    has_systemd && systemctl is-enabled --quiet "$UNIT" 2>/dev/null
}

unit_state() {
    if has_systemd; then
        systemctl is-active "$UNIT" 2>/dev/null || true
    elif iface_exists "$IFACE"; then
        echo 'active (без systemd)'
    else
        echo inactive
    fi
}

# Up through systemd or a manual wg-quick up.
iface_running() {
    iface_exists "$IFACE"
}

sys_iface_start() {
    if has_systemd; then
        systemctl enable --quiet "$UNIT" 2>/dev/null || true
        systemctl start "$UNIT"
    else
        wg-quick up "$IFACE"
    fi
}

sys_iface_stop() {
    if unit_active; then
        systemctl stop "$UNIT"
    elif iface_exists "$IFACE"; then
        wg-quick down "$IFACE"
    fi
}

sys_iface_disable() {
    sys_iface_stop || true
    has_systemd && systemctl disable --quiet "$UNIT" 2>/dev/null || true
}

# Hot update of the peer list; sessions of unchanged peers are kept. Without ListenPort in the
# config (peer nodes) wg syncconf would pick a new random port and the hub would keep sending
# to the old one until the next keepalive, so the current port is pinned explicitly.
sys_syncconf() {
    local port
    port="$(wg show "$IFACE" listen-port 2>/dev/null || true)"
    if [[ -z ${NODE[LISTEN_PORT]-} && $port =~ ^[1-9][0-9]*$ ]]; then
        wg syncconf "$IFACE" <(wg-quick strip "$LIVE_CONF" | sed "/^\[Interface\]/a ListenPort = $port")
    else
        wg syncconf "$IFACE" <(wg-quick strip "$LIVE_CONF")
    fi
}

# Last known endpoints by public key, including removed and disabled peers, so that a
# re-enabled or restored peer reconnects immediately.
endpoints_cache_update() {
    local cache="$ST_DIR/endpoints.cache"
    iface_running || return 0
    { wg show "$IFACE" endpoints 2>/dev/null | awk '$2 != "(none)"' || true; cat "$cache" 2>/dev/null || true; } |
        awk '!seen[$1]++ && ++n <= 1000' | write_atomic "$cache" 600
}

# wg syncconf does not touch routes (only wg-quick up adds them), so they are synced here with
# wg-quick's rules: add a route when the interface has none for it, delete only routes that
# were in the old config and are gone from the new one. /0 routes need wg-quick's fwmark
# handling and are left to a restart.
sys_sync_routes() {
    local old=$1 new=$2 c fam
    local -a table_args=() old_list=() new_list=()
    [[ ${NODE[TABLE]} == off ]] && return 0
    [[ ${NODE[TABLE]} =~ ^[0-9]+$ ]] && table_args=(table "${NODE[TABLE]}")
    mapfile -t old_list < <(canon_allowed_ips "$old")
    mapfile -t new_list < <(canon_allowed_ips "$new")

    for c in "${new_list[@]}"; do
        [[ ${c##*/} == 0 ]] && continue
        fam="$(ip_family "$c")"
        if [[ -z $(ip -"$fam" route show dev "$IFACE" match "$c" "${table_args[@]}" 2>/dev/null) ]]; then
            ip -"$fam" route add "$c" dev "$IFACE" "${table_args[@]}" || { log_error "не удалось добавить маршрут $c"; return 1; }
        fi
    done
    for c in "${old_list[@]}"; do
        [[ ${c##*/} == 0 ]] && continue
        [[ " ${new_list[*]} " == *" $c "* ]] && continue
        fam="$(ip_family "$c")"
        ip -"$fam" route del "$c" dev "$IFACE" "${table_args[@]}" 2>/dev/null || true
    done
}

# After a restart the hub does not know the endpoints of peers without Endpoint=, and peers
# notice the lost session only after KEEPALIVE_TIMEOUT + REKEY_TIMEOUT (~15 s). Restore the
# last known endpoints and start the handshake ourselves: setting persistent-keepalive sends
# a keepalive at once, which needs a session. Then the configured keepalive is put back.
sys_kick_handshakes() {
    local file=$1 canon=$2 t pk k v ep
    local -A conf_ep=() conf_ka=() known=()
    [[ -s $file ]] || return 0
    while IFS=$FS read -r t pk k v; do
        [[ $t == P ]] || continue
        known[$pk]=1
        [[ $k == endpoint ]] && conf_ep[$pk]=$v
        [[ $k == persistentkeepalive ]] && conf_ka[$pk]=$v
    done < "$canon"
    while read -r pk ep; do
        [[ -n ${known[$pk]-} && -z ${conf_ep[$pk]-} && $ep != '(none)' ]] || continue
        wg set "$IFACE" peer "$pk" endpoint "$ep" persistent-keepalive 1 2>/dev/null || continue
        wg set "$IFACE" peer "$pk" persistent-keepalive "${conf_ka[$pk]:-0}" 2>/dev/null || true
    done < "$file"
    return 0
}

# All AllowedIPs of a canonical config, one per line.
canon_allowed_ips() {
    awk -F "$FS" '$1 == "P" && $3 == "allowedips" { n = split($4, a, ","); for (i = 1; i <= n; i++) print a[i] }' "$1" | sort -u
}

port_in_use_udp() {
    [[ -n $(ss -Hulpn "sport = :$1" 2>/dev/null) ]]
}

firewalld_active() {
    has_cmd firewall-cmd && [[ $(firewall-cmd --state 2>/dev/null) == running ]]
}

ufw_active() {
    has_cmd ufw && output_has '^Status: active' ufw status
}

ufw_has_udp() {
    output_has "(^|[[:space:]])$1/udp([[:space:]]|$)" ufw status
}

sys_firewall_open() {
    local port=$1
    if firewalld_active; then
        log_warn "активен firewalld — wg-network им не управляет: firewall-cmd --permanent --add-port=$port/udp && firewall-cmd --reload"
        return 1
    fi
    if ! ufw_active; then
        log_warn "UFW не активен — firewall не трогаю. Убедись, что входящий UDP $port разрешён"
        return 1
    fi
    ufw_has_udp "$port" && return 0
    log_info "Открываю UDP $port в UFW"
    ufw allow "$port/udp" comment "wg-network $IFACE" >/dev/null
}

boot_id() {
    if [[ -n ${WGN_BOOT_ID-} ]]; then
        printf '%s' "$WGN_BOOT_ID"
    else
        cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown
    fi
}

# Code that root runs later (at boot, from a timer) must not be replaceable by an
# unprivileged user: the directory and all its parents must be owned by root and not writable
# by group or others. A working copy in /home does not qualify.
wgn_home_trusted() {
    local dir=$WGN_HOME owner mode
    # Isolated tests only: inside a user namespace the real root shows up as nobody.
    [[ ${WGN_UNSAFE_TRUST_HOME-} == 1 ]] && return 0
    while :; do
        read -r owner mode < <(stat -c '%u %a' "$dir" 2>/dev/null) || return 1
        [[ $owner == 0 ]] && (((8#$mode & 8#022) == 0)) || return 1
        [[ $dir == / ]] && break
        dir="$(dirname "$dir")"
    done
    read -r owner mode < <(stat -c '%u %a' "$WGN_HOME/wg-network") || return 1
    [[ $owner == 0 ]] && (((8#$mode & 8#022) == 0))
}

# Drop-in for wg-quick@: if the server reboots while a change waits for confirmation, the
# previous config is brought up at boot. The "-" prefix lets the interface start even when
# wg-network has been removed.
sys_dropin_install() {
    local content
    has_systemd || return 0
    if ! wgn_home_trusted; then
        log_warn "$WGN_HOME не защищён от записи не-root пользователями: защита от перезагрузки во время подтверждения не устанавливается (установи через install.sh)"
        return 0
    fi
    content="[Service]
ExecStartPre=-$WGN_HOME/wg-network --interface %i rollback --pending --boot --quiet
"
    [[ -f $DROPIN && $(<"$DROPIN") == "${content%$'\n'}" ]] && return 0
    install -d -m 755 "$DROPIN_DIR"
    printf '%s' "$content" | write_atomic "$DROPIN" 644
    systemctl daemon-reload
}

sys_dropin_remove() {
    [[ -f $DROPIN ]] || return 0
    rm -f -- "$DROPIN"
    rmdir -- "$DROPIN_DIR" 2>/dev/null || true
    if has_systemd; then systemctl daemon-reload; fi
}

# Rollback timer that survives a dropped SSH session: a transient systemd unit outside the
# user session, or without systemd a process in its own session (setsid) that gets no SIGHUP.
deadman_arm() {
    local txid=$1 seconds=$2 unit
    local -a cmd=("$WGN_HOME/wg-network" --interface "$IFACE" rollback --pending --txid "$txid" --auto --quiet)
    # The child must not inherit the lock fd, or it would hold the lock until it fires.
    [[ -n ${LOCK_FD-} ]] || die 'внутренняя ошибка: таймер отката без блокировки'
    if has_systemd && has_cmd systemd-run; then
        unit="wg-network-rollback-$IFACE-$txid"
        systemd-run --quiet --unit "$unit" --description "wg-network: roll back unconfirmed change of $IFACE" \
            --on-active="${seconds}s" --timer-property=AccuracySec=1s "${cmd[@]}" >/dev/null {LOCK_FD}>&-
        printf 'MECH=systemd\nTIMER=%s.timer\n' "$unit"
    else
        # A background job is not a group leader, so setsid does not fork and $! is its PID.
        # shellcheck disable=SC2016  # expanded by the inner bash
        setsid bash -c 'sleep "$1"; shift; exec "$@"' _ "$seconds" "${cmd[@]}" </dev/null >/dev/null 2>&1 {LOCK_FD}>&- &
        printf 'MECH=setsid\nTIMER=%s\n' "$!"
    fi
}

deadman_disarm() {
    local mech timer pid
    mech="$(kv_get "$ST_PENDING" MECH)"
    timer="$(kv_get "$ST_PENDING" TIMER)"
    case $mech in
        systemd) systemctl stop "$timer" 2>/dev/null || true ;;
        setsid)
            pid=$timer
            # The PID may have been reused: kill it only if it is still our timer.
            if [[ $pid =~ ^[0-9]+$ && $pid != "$$" ]] &&
                [[ $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) == *"--txid $(kv_get "$ST_PENDING" TXID)"* ]]; then
                # SIGKILL: an inherited "ignore SIGTERM" would survive (the process is sleep + exec).
                kill -KILL "$pid" 2>/dev/null || true
            fi
            ;;
    esac
}

# Established SSH sessions as "client local_address". Sessions of every administrator count,
# not only the current one: sudo usually does not pass SSH_CONNECTION.
ssh_sessions() {
    local -A ports=([22]=1) seen=()
    local line local_addr peer_addr port client server key value
    if has_cmd sshd; then
        while read -r key value; do
            [[ $key == port && $value =~ ^[0-9]+$ ]] && ports[$value]=1
        done < <(sshd -T 2>/dev/null || true)
    fi
    while read -r _ _ _ local_addr _ line; do
        [[ $line == *'"sshd'* ]] || continue
        port=${local_addr##*:}
        [[ $port =~ ^[0-9]+$ ]] && ports[$port]=1
    done < <(ss -Htlnp 2>/dev/null)

    while read -r _ _ local_addr peer_addr _; do
        port=${local_addr##*:}
        [[ -n ${ports[$port]-} ]] || continue
        client=${peer_addr%:*}
        server=${local_addr%:*}
        client=${client#[}; client=${client%]}; client=${client#::ffff:}
        server=${server#[}; server=${server%]}; server=${server#::ffff:}
        server=${server%%%*}
        is_ip "$client" || continue
        [[ -n ${seen["$client $server"]-} ]] && continue
        seen["$client $server"]=1
        printf '%s %s\n' "$client" "$server"
    done < <(ss -Htn state established 2>/dev/null)

    if [[ -n ${SSH_CONNECTION-} ]]; then
        read -r client _ server _ <<< "$SSH_CONNECTION"
        client=${client#::ffff:}
        server=${server#::ffff:}
        is_ip "$client" && [[ -z ${seen["$client $server"]-} ]] && printf '%s %s\n' "$client" "$server"
    fi
    return 0
}

# Longest prefix among routes to IP in the main table, ignoring our interface.
best_route_prefix() {
    local ip=$1 fam best=-1 len dst
    fam="$(ip_family "$ip")"
    while read -r dst _; do
        case $dst in
            default) len=0 ;;
            */*) len=${dst##*/} ;;
            *) len=$((fam == 4 ? 32 : 128)) ;;
        esac
        ((len > best)) && best=$len
    done < <(ip -"$fam" route show table main match "$ip" 2>/dev/null | grep -v " dev $IFACE\( \|$\)" || true)
    printf '%s' "$best"
}

iface_addresses() {
    { ip -o addr show dev "$1" 2>/dev/null || true; } | awk '{ sub(/\/.*/, "", $4); print $4 }'
}

# Routes of the main table overlapping CIDR, ignoring our interface.
local_route_conflicts() {
    local cidr=$1 fam dst dev rest
    fam="$(ip_family "${cidr%/*}")"
    while read -r dst rest; do
        [[ $dst == default ]] && continue
        [[ $rest =~ (^|\ )dev\ ([^ ]+) ]] && dev=${BASH_REMATCH[2]} || dev=''
        [[ $dev == "$IFACE" ]] && continue
        [[ $dst == */* ]] || dst="$dst/$((fam == 4 ? 32 : 128))"
        is_cidr "$dst" || continue
        cidr_overlap "$dst" "$cidr" && printf '%s dev %s\n' "$dst" "$dev"
    done < <(ip -"$fam" route show table main 2>/dev/null)
    return 0
}
