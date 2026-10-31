# shellcheck shell=bash
# Kernel view of peers (wg show dump) joined with names from the state.

# Fills RT_ENDPOINT, RT_HANDSHAKE, RT_RX, RT_TX keyed by public key.
runtime_load() {
    declare -gA RT_ENDPOINT=() RT_HANDSHAKE=() RT_RX=() RT_TX=()
    RT_UP=0
    iface_running || return 0
    RT_UP=1
    local pk psk endpoint ips hs rx tx ka
    while IFS=$'\t' read -r pk psk endpoint ips hs rx tx ka; do
        RT_ENDPOINT[$pk]=$endpoint
        RT_HANDSHAKE[$pk]=$hs
        RT_RX[$pk]=$rx
        RT_TX[$pk]=$tx
    done < <(wg show "$IFACE" dump 2>/dev/null | tail -n +2)
}

handshake_text() {
    local hs=${1-}
    if [[ -z $hs ]]; then
        printf '-'
    elif [[ $hs == 0 ]]; then
        printf 'never'
    else
        printf '%s ago' "$(human_age $(($(now_epoch) - hs)))"
    fi
}

peer_state_text() {
    local enabled=$1 pending=$2 hs=${3-}
    if [[ $pending == 1 ]]; then
        printf 'invited'
    elif [[ $enabled != 1 ]]; then
        printf 'disabled'
    elif [[ -z $hs ]]; then
        printf 'down'
    elif [[ $hs == 0 ]]; then
        printf 'no-handshake'
    elif (($(now_epoch) - hs > 180)); then
        printf 'stale'
    else
        printf 'online'
    fi
}

peers_table() {
    local name key addr addr6 routes endpoint keepalive enabled pending psk comment hs
    runtime_load
    printf '%-20s %-15s %-13s %-22s %-10s %-10s %-10s %s\n' NAME ADDRESS STATE ENDPOINT HANDSHAKE RX TX ROUTES
    while IFS=$FS read -r name key addr addr6 routes endpoint keepalive enabled pending psk comment; do
        hs=${RT_HANDSHAKE[$key]-}
        printf '%-20s %-15s %-13s %-22s %-10s %-10s %-10s %s\n' "$name" "${addr:--}" \
            "$(peer_state_text "$enabled" "$pending" "$hs")" "${RT_ENDPOINT[$key]:-${endpoint:--}}" \
            "$(handshake_text "$hs")" "$(human_bytes "${RT_RX[$key]:-0}")" "$(human_bytes "${RT_TX[$key]:-0}")" "${routes:--}"
    done < <(st_peers_tsv)
}

peers_json() {
    local name key addr addr6 routes endpoint keepalive enabled pending psk comment hs first=1
    runtime_load
    printf '['
    while IFS=$FS read -r name key addr addr6 routes endpoint keepalive enabled pending psk comment; do
        hs=${RT_HANDSHAKE[$key]-}
        ((first)) || printf ','
        first=0
        printf '{"name":%s,"public_key":%s,"address":%s,"address6":%s,"routes":%s,"endpoint":%s,' \
            "$(json_str "$name")" "$(json_str "$key")" "$(json_str "$addr")" "$(json_str "$addr6")" \
            "$(json_str "$routes")" "$(json_str "${RT_ENDPOINT[$key]:-$endpoint}")"
        printf '"state":%s,"latest_handshake":%s,"rx_bytes":%s,"tx_bytes":%s,"comment":%s}' \
            "$(json_str "$(peer_state_text "$enabled" "$pending" "$hs")")" "${hs:-null}" \
            "${RT_RX[$key]:-0}" "${RT_TX[$key]:-0}" "$(json_str "$comment")"
    done < <(st_peers_tsv)
    printf ']'
}

# wait_handshake KEY TIMEOUT: status 0 once the peer has completed a handshake.
wait_handshake() {
    local key=$1 timeout=$2 deadline hs
    deadline=$(($(now_epoch) + timeout))
    while :; do
        hs="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk -v k="$key" '$1 == k { print $2 }')"
        [[ -n $hs && $hs != 0 ]] && return 0
        (($(now_epoch) >= deadline)) && return 1
        sleep 0.5
    done
}

# applied | pending | written | prepared | dry-run
apply_outcome() {
    if ((OPT_DRY_RUN)); then
        echo dry-run
    elif [[ ${APPLIED:-0} == pending ]]; then
        echo pending
    elif [[ ${APPLIED:-0} == offline ]]; then
        echo written
    elif [[ ${APPLIED:-0} == 1 || ${PLAN_CLASS:-} == none ]]; then
        echo applied
    else
        echo prepared
    fi
}

outcome_text() {
    case "$(apply_outcome)" in
        applied) printf 'применено' ;;
        pending) printf 'применено, ждёт подтверждения' ;;
        written) printf 'записано в конфиг, интерфейс остановлен (wg-network apply --start)' ;;
        prepared) printf 'сохранено, но НЕ применено (wg-network apply)' ;;
        dry-run) printf 'dry-run, ничего не изменено' ;;
    esac
}
