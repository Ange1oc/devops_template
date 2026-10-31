# shellcheck shell=bash

CMD_SUMMARY='временно отключить peer, сохранив его настройки'
CMD_GROUP=peers
CMD_MUTATES=1

cmd_usage() {
    echo 'Использование: wg-network [-i IFACE] peer disable NAME   (обратно: peer enable NAME)'
}

cmd_run() {
    peer_toggle 0 "$@"
}
