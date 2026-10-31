# shellcheck shell=bash
# Desired state of a node and safe changes to it.
#
#   /etc/wireguard/wg-network/<iface>/
#     node.env            interface parameters and role (hub | peer)
#     private.key         interface private key
#     peers.d/<name>.env  one file per peer; a peer node has a single peer named "hub"
#     snapshots/          state before every change (wg-network history / rollback)
#     rendered.sha256     hash of the last /etc/wireguard/<iface>.conf we wrote (not snapshotted)
#     tx.env              unfinished transaction, recovered after a crash
#     pending.env         applied but not yet confirmed configuration
#
# /etc/wireguard/<iface>.conf is derived: it is always rendered from the state.

declare -gA NODE=()
declare -gA PEER=()

st_exists() {
    [[ -f $ST_NODE ]]
}

require_managed() {
    st_exists || die "интерфейс $IFACE не управляется wg-network (wg-network init-hub / join)"
}

# An existing /etc/wireguard is left as is; under --dry-run only the sandbox is created.
st_prepare_dirs() {
    if ! ((OPT_DRY_RUN)); then
        [[ -d $WG_DIR ]] || install -d -m 700 "$WG_DIR"
        [[ -d $WGN_ROOT ]] || install -d -m 700 "$WGN_ROOT"
    fi
    install -d -m 700 "$ST_DIR" "$ST_PEERS" "$ST_SNAPSHOTS"
}

st_node_load() {
    kv_load "$ST_NODE" NODE
    : "${NODE[TABLE]:=auto}" "${NODE[FORWARD]:=0}"
}

st_node_save() {
    NODE[SCHEMA]=$SCHEMA_VERSION
    kv_save "$ST_NODE" NODE "${NODE_KEYS[@]}"
}

require_role() {
    [[ ${NODE[ROLE]-} == "$1" ]] || die_code "$E_REFUSED" "команда выполняется только на узле с ролью $1 (у $IFACE роль '${NODE[ROLE]-}')"
}

st_peer_file() {
    printf '%s/%s.env' "$ST_PEERS" "$1"
}

st_peer_exists() {
    [[ -f $(st_peer_file "$1") ]]
}

st_peer_load() {
    st_peer_exists "$1" || die "peer '$1' не найден"
    kv_load "$(st_peer_file "$1")" PEER
    : "${PEER[ENABLED]:=1}" "${PEER[PENDING]:=0}"
}

st_peer_save() {
    PEER[UPDATED_AT]="$(now_iso)"
    : "${PEER[CREATED_AT]:=${PEER[UPDATED_AT]}}"
    kv_save "$(st_peer_file "$1")" PEER "${PEER_KEYS[@]}"
}

st_peer_delete() {
    rm -f -- "$(st_peer_file "$1")"
}

st_peer_names() {
    local f
    for f in "$ST_PEERS"/*.env; do
        [[ -f $f ]] || continue
        f=${f##*/}
        printf '%s\n' "${f%.env}"
    done
}

# One line per peer, fields separated by $FS (not TAB: read merges empty TAB fields):
# name pubkey address address6 routes endpoint keepalive enabled pending psk comment
st_peers_tsv() {
    local name
    local -A p=()
    while IFS= read -r name; do
        kv_load "$(st_peer_file "$name")" p
        printf "%s$FS%s$FS%s$FS%s$FS%s$FS%s$FS%s$FS%s$FS%s$FS%s$FS%s\n" "$name" \
            "${p[PUBLIC_KEY]-}" "${p[ADDRESS]-}" "${p[ADDRESS6]-}" "${p[ROUTES]-}" \
            "${p[ENDPOINT]-}" "${p[KEEPALIVE]-}" "${p[ENABLED]:-1}" "${p[PENDING]:-0}" \
            "${p[PSK]-}" "${p[COMMENT]-}"
    done < <(st_peer_names)
}

# AllowedIPs of a peer: its tunnel addresses plus the networks behind it.
peer_allowed_ips() {
    local addr=$1 addr6=$2 routes=$3
    local -a out=() extra=()
    [[ -n $addr ]] && out+=("$addr/32")
    [[ -n $addr6 ]] && out+=("$addr6/128")
    split_csv "$routes" extra
    out+=("${extra[@]}")
    join_by ', ' "${out[@]}"
}

# Networks of the hub interface (routes offered to peers when FORWARD=1).
node_networks() {
    local net4 net6
    cidr_network "${NODE[ADDRESS]}" net4
    printf '%s' "$net4"
    if [[ -n ${NODE[ADDRESS6]-} ]]; then
        cidr_network "${NODE[ADDRESS6]}" net6
        printf ',%s' "$net6"
    fi
}

# st_owner_of_cidr CIDR [EXCEPT]: the peer whose address or route overlaps CIDR.
st_owner_of_cidr() {
    local cidr=$1 except=${2-} name key addr addr6 routes rest c
    local -a list=() extra_routes=()
    while IFS=$FS read -r name key addr addr6 routes rest; do
        [[ $name == "$except" ]] && continue
        list=()
        [[ -n $addr ]] && list+=("$addr/32")
        [[ -n $addr6 ]] && list+=("$addr6/128")
        split_csv "$routes" extra_routes
        list+=("${extra_routes[@]}")
        for c in "${list[@]}"; do
            if cidr_overlap "$c" "$cidr"; then
                printf '%s (%s)' "$name" "$c"
                return 0
            fi
        done
    done < <(st_peers_tsv)
    return 1
}

st_owner_of_key() {
    local want=$1 except=${2-} name key rest
    while IFS=$FS read -r name key rest; do
        [[ $name != "$except" && -n $key && $key == "$want" ]] && { printf '%s' "$name"; return 0; }
    done < <(st_peers_tsv)
    return 1
}

# First free IPv4 address in the hub network; invite reservations count as used.
st_next_free_ip4() {
    local hub=${NODE[ADDRESS]%/*} net bcast n candidate name key addr rest
    local -A used=([$hub]=1)
    while IFS=$FS read -r name key addr rest; do
        [[ -n $addr ]] && used[$addr]=1
    done < <(st_peers_tsv)
    read -r net bcast <<< "$(ip4_bounds "${NODE[ADDRESS]}")"
    for ((n = net + 1; n < bcast; n++)); do
        ip4_from_int "$n" candidate
        [[ -z ${used[$candidate]-} ]] && { printf '%s' "$candidate"; return 0; }
    done
    die "в сети ${NODE[ADDRESS]} не осталось свободных адресов"
}

st_derive_ip6() {
    local index out
    [[ -n ${NODE[ADDRESS6]-} ]] || return 0
    index="$(ip4_host_index "${NODE[ADDRESS]}" "$1")"
    ip6_from_index "${NODE[ADDRESS6]}" "$index" out
    printf '%s' "$out"
}

st_check_peer_address() {
    local ip=$1 name=$2 owner
    is_ipv4 "$ip" || die_usage "некорректный IPv4: $ip"
    ip4_is_host_in "${NODE[ADDRESS]}" "$ip" || die_usage "$ip не входит в сеть ${NODE[ADDRESS]}"
    [[ $ip != "${NODE[ADDRESS]%/*}" ]] || die_usage "$ip — адрес самого hub"
    if owner="$(st_owner_of_cidr "$ip/32" "$name")"; then
        die_usage "$ip уже занят: $owner"
    fi
}

# A route behind a peer must not overlap the hub network or another peer: WireGuard maps
# every address to exactly one peer, so an overlap silently steals traffic.
st_check_peer_routes() {
    local name=$1 c owner
    local -a routes=()
    split_csv "$2" routes
    for c in "${routes[@]}"; do
        check_route "$c"
        if cidr_overlap "$c" "${NODE[ADDRESS]}" || { [[ -n ${NODE[ADDRESS6]-} ]] && cidr_overlap "$c" "${NODE[ADDRESS6]}"; }; then
            [[ ${NODE[ROLE]} == peer ]] || die_usage "маршрут $c пересекается с сетью wg-network"
        fi
        if [[ ${c##*/} == 0 && ${NODE[ROLE]} == hub ]]; then
            die_usage "маршрут $c на hub отправит весь трафик сервера в одного peer"
        fi
        if owner="$(st_owner_of_cidr "$c" "$name")"; then
            die_usage "маршрут $c пересекается с $owner"
        fi
    done
}

# Validate the state before rendering: a damaged or tampered file must never become a live
# config. Prints one line per problem.
st_validate() {
    local errors=0 name key addr addr6 routes endpoint keepalive enabled pending psk comment c
    local -a list=()
    err() { printf '%s\n' "$*"; errors=$((errors + 1)); }

    [[ ${NODE[ROLE]-} =~ ^(hub|peer)$ ]] || err "node.env: ROLE должен быть hub или peer"
    is_name "${NODE[NAME]-}" || err "node.env: некорректный NAME"
    if [[ ${NODE[ROLE]-} == hub ]]; then
        is_iface_cidr4 "${NODE[ADDRESS]-}" || err "node.env: некорректный ADDRESS"
        is_port "${NODE[LISTEN_PORT]-}" || err "node.env: некорректный LISTEN_PORT"
        is_endpoint "${NODE[ENDPOINT]-}" || err "node.env: некорректный ENDPOINT"
    else
        [[ ${NODE[ADDRESS]-} =~ /32$ ]] && is_ipv4 "${NODE[ADDRESS]%/32}" || err "node.env: ADDRESS peer должен быть IPv4/32"
        [[ -z ${NODE[LISTEN_PORT]-} ]] || is_port "${NODE[LISTEN_PORT]}" || err "node.env: некорректный LISTEN_PORT"
    fi
    if [[ -n ${NODE[ADDRESS6]-} ]]; then
        is_cidr "${NODE[ADDRESS6]}" && is_ipv6 "${NODE[ADDRESS6]%/*}" || err "node.env: некорректный ADDRESS6"
    fi
    [[ -z ${NODE[MTU]-} ]] || is_mtu "${NODE[MTU]}" || err "node.env: MTU должен быть 1280..9000"
    is_table "${NODE[TABLE]-}" || err "node.env: некорректный TABLE"
    is_bool "${NODE[FORWARD]-}" || err "node.env: FORWARD должен быть 0 или 1"
    [[ -z ${NODE[NAT]-} ]] || is_iface "${NODE[NAT]}" || err "node.env: некорректный NAT"
    [[ -s $ST_KEY ]] && is_wg_key "$(<"$ST_KEY")" || err "private.key отсутствует или повреждён"

    while IFS=$FS read -r name key addr addr6 routes endpoint keepalive enabled pending psk comment; do
        is_name "$name" || err "peers.d: некорректное имя файла '$name'"
        if [[ $pending == 1 ]]; then
            [[ -z $key ]] || is_wg_key "$key" || err "peer $name: некорректный PUBLIC_KEY"
        else
            is_wg_key "$key" || err "peer $name: некорректный PUBLIC_KEY"
        fi
        [[ -z $psk ]] || is_wg_key "$psk" || err "peer $name: некорректный PSK"
        [[ -z $addr ]] || is_ipv4 "$addr" || err "peer $name: некорректный ADDRESS"
        [[ -z $addr6 ]] || is_ipv6 "$addr6" || err "peer $name: некорректный ADDRESS6"
        split_csv "$routes" list
        for c in "${list[@]}"; do
            is_cidr "$c" || err "peer $name: некорректный маршрут $c"
        done
        [[ -n $addr || ${#list[@]} -gt 0 ]] || err "peer $name: нет ни адреса, ни маршрутов"
        [[ -z $endpoint ]] || is_endpoint "$endpoint" || err "peer $name: некорректный ENDPOINT"
        [[ -z $keepalive ]] || is_keepalive "$keepalive" || err "peer $name: некорректный KEEPALIVE"
        is_bool "$enabled" && is_bool "$pending" || err "peer $name: ENABLED/PENDING должны быть 0 или 1"
        is_comment "$comment" || err "peer $name: недопустимые символы в COMMENT"
    done < <(st_peers_tsv)
    unset -f err
    ((errors == 0))
}

st_require_valid() {
    local problems
    if ! problems="$(st_validate)"; then
        log_error "состояние $ST_DIR повреждено:"
        printf '  %s\n' "$problems" >&2
        die "исправь файлы вручную или откати: wg-network -i $IFACE rollback"
    fi
}

lock_acquire() {
    [[ -n ${LOCK_FD-} ]] && return 0
    ((OPT_DRY_RUN)) && return 0
    [[ -d $WG_DIR ]] || install -d -m 700 "$WG_DIR"
    [[ -d $WGN_ROOT ]] || install -d -m 700 "$WGN_ROOT"
    if ! { exec {LOCK_FD}> "$ST_LOCK"; } 2>/dev/null; then
        unset LOCK_FD
        die "не удалось открыть $ST_LOCK (файловая система только для чтения или нет места?)"
    fi
    if ! flock -w "$LOCK_WAIT" "$LOCK_FD"; then
        exec {LOCK_FD}>&-
        unset LOCK_FD
        die_code "$E_BUSY" "интерфейс $IFACE занят другим процессом wg-network (ждал ${LOCK_WAIT}s)"
    fi
}

lock_release() {
    [[ -n ${LOCK_FD-} ]] || return 0
    exec {LOCK_FD}>&-
    unset LOCK_FD
}

# Snapshot of the state and the live config. Prints the snapshot id.
snap_create() {
    local label=$1 id tmp item
    install -d -m 700 "$ST_SNAPSHOTS"
    id="$(date +%Y%m%d-%H%M%S)-$label"
    while [[ -e $ST_SNAPSHOTS/$id.tar ]]; do
        id="$id+"
    done
    tmp="$(mktemp -d "$ST_DIR/.snap.XXXXXX")"
    for item in node.env private.key peers.d; do
        [[ -e $ST_DIR/$item ]] && cp -a "$ST_DIR/$item" "$tmp/"
    done
    [[ -f $LIVE_CONF ]] && cp -p "$LIVE_CONF" "$tmp/live.conf"
    printf 'ID=%s\nCREATED_AT=%s\nLABEL=%s\nHAD_STATE=%s\nHAD_LIVE=%s\nVERSION=%s\n' \
        "$id" "$(now_iso)" "$label" "$([[ -f $ST_NODE ]] && echo 1 || echo 0)" \
        "$([[ -f $LIVE_CONF ]] && echo 1 || echo 0)" "$(wgn_version)" > "$tmp/meta.env"
    if ! (umask 077 && tar -C "$tmp" -cf "$ST_SNAPSHOTS/$id.tar" .); then
        rm -rf -- "$tmp" "$ST_SNAPSHOTS/$id.tar"
        die 'не удалось создать снимок (нет места или файловая система только для чтения) — ничего не изменено'
    fi
    rm -rf -- "$tmp"
    printf '%s' "$id"
}

snap_prune() {
    local -a all=()
    local i
    mapfile -t all < <(find "$ST_SNAPSHOTS" -maxdepth 1 -name '*.tar' -printf '%f\n' | sort)
    for ((i = 0; i < ${#all[@]} - SNAPSHOT_KEEP; i++)); do
        rm -f -- "$ST_SNAPSHOTS/${all[i]}"
    done
}

snap_list() {
    find "$ST_SNAPSHOTS" -maxdepth 1 -name '*.tar' -printf '%f\n' 2>/dev/null | sort -r | sed 's/\.tar$//'
}

snap_extract() {
    local id=$1 dest=$2
    [[ $id =~ ^[0-9]{8}-[0-9]{6}-[a-z0-9-]+\+*$ && -f $ST_SNAPSHOTS/$id.tar ]] || die "снимок '$id' не найден (wg-network history)"
    tar -C "$dest" -xf "$ST_SNAPSHOTS/$id.tar" || die "снимок $id повреждён"
}

# Restore the desired state from a snapshot. The live config and rendered.sha256 are left
# alone: only an apply changes them.
snap_restore_state() {
    local id=$1 tmp item
    tmp="$(mktemp -d "$ST_DIR/.restore.XXXXXX")"
    snap_extract "$id" "$tmp"
    for item in node.env private.key peers.d; do
        rm -rf -- "${ST_DIR:?}/$item"
        [[ -e $tmp/$item ]] && mv -- "$tmp/$item" "$ST_DIR/$item"
    done
    install -d -m 700 "$ST_PEERS"
    rm -rf -- "$tmp"
}

# A transaction over the state: a snapshot before the change and an automatic restore if the
# command dies halfway (error, Ctrl+C, kill). After kill -9 the next run restores it.
tx_begin() {
    local label=$1
    lock_acquire
    tx_recover
    pending_refuse
    st_prepare_dirs
    TX_SNAPSHOT="$(snap_create "$label")"
    printf 'SNAPSHOT=%s\nPID=%s\nBOOT_ID=%s\nLABEL=%s\n' "$TX_SNAPSHOT" "$$" "$(boot_id)" "$label" | write_atomic "$ST_TX" 600
    TX_ACTIVE=1
    EXIT_HOOKS+=(tx_exit_hook)
}

# Old snapshots are pruned only after a successful change, so a refused operation cannot push
# a real restore point out.
tx_commit() {
    rm -f -- "$ST_TX"
    TX_ACTIVE=0
    snap_prune
}

tx_exit_hook() {
    ((${TX_ACTIVE:-0})) || return 0
    TX_ACTIVE=0
    log_warn "команда не завершилась — восстанавливаю состояние из снимка $TX_SNAPSHOT"
    if (snap_restore_state "$TX_SNAPSHOT"); then
        rm -f -- "$ST_TX"
        # The state equals the snapshot again; keeping it would only crowd out real restore points.
        rm -f -- "$ST_SNAPSHOTS/$TX_SNAPSHOT.tar"
        audit "tx-aborted snapshot=$TX_SNAPSHOT"
    else
        log_error "состояние восстановить не удалось; tx.env оставлен — восстановление повторится при следующем запуске (или: wg-network rollback $TX_SNAPSHOT)"
        audit "tx-restore-failed snapshot=$TX_SNAPSHOT"
    fi
}

# The owner of a transaction may legitimately be alive without holding the lock: deadman_wait
# releases it while waiting for confirmation. A PID from another boot or of an unrelated
# process (PID reuse) does not count.
tx_owner_alive() {
    local pid=$1 boot=$2
    [[ $pid =~ ^[0-9]+$ && $pid != "$$" ]] || return 1
    [[ -z $boot || $boot == "$(boot_id)" ]] || return 1
    [[ $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) == *wg-network* ]]
}

tx_recover() {
    local snap pid
    [[ -f $ST_TX ]] || return 0
    snap="$(kv_get "$ST_TX" SNAPSHOT)"
    pid="$(kv_get "$ST_TX" PID)"
    if tx_owner_alive "$pid" "$(kv_get "$ST_TX" BOOT_ID)"; then
        die_code "$E_BUSY" "незавершённая транзакция процесса $pid"
    fi
    log_warn "найдена прерванная транзакция — восстанавливаю состояние из снимка $snap"
    snap_restore_state "$snap"
    rm -f -- "$ST_TX"
    audit "tx-recovered snapshot=$snap"
}

pending_exists() {
    [[ -f $ST_PENDING ]]
}

pending_refuse() {
    pending_exists || return 0
    die_code "$E_BUSY" "есть применённая, но не подтверждённая конфигурация (до $(date -d "@$(kv_get "$ST_PENDING" DEADLINE)" +%T)). Сначала: wg-network -i $IFACE confirm  или  rollback"
}
