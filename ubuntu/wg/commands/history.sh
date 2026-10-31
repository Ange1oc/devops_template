# shellcheck shell=bash

CMD_SUMMARY='снимки состояния (точки отката)'
CMD_GROUP=apply
CMD_READONLY=1

cmd_usage() {
    echo 'Использование: wg-network [-i IFACE] history   (вернуть: wg-network rollback SNAPSHOT)'
}

cmd_run() {
    local id
    (($# == 0)) || die_unknown_arg "$1"
    require_managed
    printf '%-40s %s\n' SNAPSHOT 'СДЕЛАН ПЕРЕД'
    while IFS= read -r id; do
        printf '%-40s %s\n' "$id" "${id#*-*-}"
    done < <(snap_list)
}
