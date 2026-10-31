# shellcheck shell=bash

CMD_SUMMARY='подтвердить применённую конфигурацию (отменить таймер отката)'
CMD_GROUP=apply

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] confirm

Запускай из НОВОЙ SSH-сессии: так подтверждается, что доступ к серверу после изменения есть.
EOF
}

cmd_run() {
    (($# == 0)) || die_unknown_arg "$1"
    require_managed
    lock_acquire
    pending_exists || die 'нет конфигурации, ожидающей подтверждения'
    pending_confirm
}
