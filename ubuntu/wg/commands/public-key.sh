# shellcheck shell=bash

CMD_SUMMARY='публичный ключ узла'
CMD_GROUP=diag
CMD_READONLY=1

cmd_usage() {
    echo 'Использование: wg-network [-i IFACE] public-key'
}

cmd_run() {
    (($# == 0)) || die_unknown_arg "$1"
    require_managed
    node_public_key
}
