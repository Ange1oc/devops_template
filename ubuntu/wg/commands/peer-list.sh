# shellcheck shell=bash

CMD_SUMMARY='список peer с состоянием соединения'
CMD_GROUP=peers
CMD_READONLY=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] peer list [--json]

STATE: online — handshake не старше 3 минут; stale — старше; no-handshake — ни разу;
       down — интерфейс не запущен; disabled — отключён; invited — ждёт peer add.
EOF
}

cmd_run() {
    local json=0
    while (($#)); do
        case $1 in
            --json) json=1; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    require_managed
    st_node_load
    if ((json)); then
        peers_json
        echo
    else
        peers_table
    fi
}
