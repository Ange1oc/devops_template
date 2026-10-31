# shellcheck shell=bash

CMD_SUMMARY='применить подготовленные изменения'
CMD_GROUP=apply
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] apply [--start] [--diff]

  --start   запустить интерфейс, если он остановлен (иначе конфиг только записывается)

Изменения peer применяются горячо (wg syncconf), изменения [Interface] — перезапуском под
таймером отката: без подтверждения конфигурация вернётся сама через CONFIRM_TIMEOUT секунд,
даже если SSH-сессия оборвётся. Перезагрузка до подтверждения тоже вернёт старый конфиг.
EOF
}

cmd_run() {
    while (($#)); do
        case $1 in
            --start) OPT_START=1; shift ;;
            --diff) OPT_SHOW_DIFF=1; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    require_managed
    lock_acquire
    tx_recover
    pending_refuse
    # Running apply is the approval; guards still ask for their own confirmation.
    OPT_APPLY=1
    apply_changes
}
