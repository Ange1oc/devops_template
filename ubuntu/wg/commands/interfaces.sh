# shellcheck shell=bash

CMD_SUMMARY='интерфейсы под управлением wg-network'
CMD_GROUP=diag
CMD_READONLY=1
CMD_IFACE=0

cmd_usage() {
    echo 'Использование: wg-network interfaces'
}

cmd_run() {
    local iface
    (($# == 0)) || die_unknown_arg "$1"
    printf '%-12s %-6s %-20s %-10s %s\n' IFACE ROLE ADDRESS STATE PEERS
    while IFS= read -r iface; do
        iface_use "$iface"
        st_node_load
        printf '%-12s %-6s %-20s %-10s %s\n' "$iface" "${NODE[ROLE]}" "${NODE[ADDRESS]}" "$(unit_state)" "$(st_peer_names | wc -l)"
    done < <(managed_ifaces)
}
