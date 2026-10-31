# shellcheck shell=bash

CMD_SUMMARY='включить отключённый peer'
CMD_GROUP=peers
CMD_MUTATES=1

cmd_usage() {
    echo 'Использование: wg-network [-i IFACE] peer enable NAME'
}

cmd_run() {
    peer_toggle 1 "$@"
}
