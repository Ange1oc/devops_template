# shellcheck shell=bash

CMD_SUMMARY='подробности о peer'
CMD_GROUP=peers
CMD_READONLY=1

cmd_usage() {
    echo 'Использование: wg-network [-i IFACE] peer show NAME'
}

cmd_run() {
    local name=${1-} hs key
    (($# == 1)) || die_usage 'укажи одно имя peer'
    is_name "$name" || die_usage "некорректное имя: $name"
    require_managed
    st_node_load
    st_peer_load "$name"
    runtime_load
    key=${PEER[PUBLIC_KEY]-}
    hs=${RT_HANDSHAKE[$key]-}
    printf 'Имя:          %s\n' "$name"
    printf 'Состояние:    %s\n' "$(peer_state_text "${PEER[ENABLED]}" "${PEER[PENDING]}" "$hs")"
    printf 'PublicKey:    %s\n' "${key:-—}"
    printf 'PSK:          %s\n' "$([[ -n ${PEER[PSK]-} ]] && echo есть || echo нет)"
    printf 'Адрес:        %s\n' "${PEER[ADDRESS]:-—}${PEER[ADDRESS6]:+, ${PEER[ADDRESS6]}}"
    printf 'AllowedIPs:   %s\n' "$(peer_allowed_ips "${PEER[ADDRESS]-}" "${PEER[ADDRESS6]-}" "${PEER[ROUTES]-}")"
    printf 'Endpoint:     %s\n' "${RT_ENDPOINT[$key]:-${PEER[ENDPOINT]:-—}}"
    printf 'Keepalive:    %s\n' "${PEER[KEEPALIVE]:-—}"
    printf 'Handshake:    %s\n' "$(handshake_text "$hs")"
    printf 'Трафик:       rx %s, tx %s\n' "$(human_bytes "${RT_RX[$key]:-0}")" "$(human_bytes "${RT_TX[$key]:-0}")"
    printf 'Комментарий:  %s\n' "${PEER[COMMENT]:-—}"
    printf 'Создан:       %s\n' "${PEER[CREATED_AT]:-—}"
}
