# shellcheck shell=bash

CMD_SUMMARY='удалить peer или приглашение'
CMD_GROUP=peers
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] peer remove NAME

Peer отключается сразу после применения (остальные туннели не прерываются).
Запись остаётся в снимке: вернуть можно через wg-network rollback.
EOF
}

cmd_run() {
    local name=${1-}
    (($# == 1)) || die_usage 'укажи одно имя peer'
    is_name "$name" || die_usage "некорректное имя: $name"
    require_managed
    st_node_load
    require_role hub
    st_peer_exists "$name" || die "peer '$name' не найден"

    tx_begin peer-remove
    st_peer_delete "$name"
    audit "peer-remove name=$name"
    apply_changes
    tx_commit
    log_ok "Peer '$name' удалён из состояния: $(outcome_text) (снимок: $TX_SNAPSHOT)"
}
