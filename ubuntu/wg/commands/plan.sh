# shellcheck shell=bash

CMD_SUMMARY='показать неприменённые изменения (ничего не меняет)'
CMD_GROUP=apply
CMD_READONLY=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] plan [--diff]

Сравнивает действующий /etc/wireguard/IFACE.conf с конфигом, построенным из состояния,
показывает способ применения и предупреждения предохранителей. Код выхода: 0 — изменений
нет (в том числе если отличается только оформление файла, например шапка после обновления),
10 — есть неприменённые изменения (удобно для мониторинга и CI).
EOF
}

cmd_run() {
    while (($#)); do
        case $1 in
            --diff) OPT_SHOW_DIFF=1; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    require_managed
    plan_build
    plan_print
    ((OPT_SHOW_DIFF)) && plan_diff
    # A rewrite changes only the file's form (e.g. the header after an upgrade): not a pending change.
    if [[ $PLAN_CLASS == rewrite ]]; then
        drift_detected && log_info "$LIVE_CONF изменён вручную без изменения смысла: следующее применение перезапишет его"
        return 0
    fi
    [[ $PLAN_CLASS == none ]] && return 0
    drift_detected && log_warn "$LIVE_CONF изменён вручную: apply потребует --force"
    pending_exists && log_warn 'есть применённая, но не подтверждённая конфигурация (confirm / rollback)'
    guard_check "$PLAN_OLD" "$PLAN_NEW" "$PLAN_CLASS"
    guard_report
    exit 10
}
