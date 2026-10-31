# shellcheck shell=bash

CMD_SUMMARY='откатить неподтверждённое применение или вернуть снимок'
CMD_GROUP=apply
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование:
  wg-network [-i IFACE] rollback            неподтверждённое применение — сразу; иначе последний снимок
  wg-network [-i IFACE] rollback SNAPSHOT   вернуть состояние из снимка (список: wg-network history)

Возврат снимка восстанавливает желаемое состояние (peer, параметры, ключ) и применяет его
обычным путём: с планом, предохранителями и таймером отката. Снимок делается перед каждым
изменением, поэтому rollback без аргументов отменяет последнее изменение, а повторный
rollback отменяет сам откат. Неподтверждённое или неудавшееся изменение сохраняется снимком
с меткой rejected: повторить его — wg-network rollback ID.
Служебные режимы (таймер и загрузка): --pending [--txid ID] [--auto | --boot].
EOF
}

cmd_run() {
    local snapshot='' pending=0 txid='' mode=manual
    while (($#)); do
        case $1 in
            --pending) pending=1; shift ;;
            --txid) require_arg "$@"; txid=$2; shift 2 ;;
            --auto) mode=auto; shift ;;
            --boot) mode=boot; shift ;;
            -*) die_unknown_arg "$1" ;;
            *) [[ -z $snapshot ]] || die_unknown_arg "$1"; snapshot=$1; shift ;;
        esac
    done

    # From ExecStartPre: the interface must start whatever happens here. The lock is taken only
    # once a rollback is known to be needed, because ExecStartPre also runs on every start that
    # wg-network itself performs while holding the lock.
    if [[ $mode == boot ]]; then
        st_exists && pending_exists || return 0
        [[ $(kv_get "$ST_PENDING" BOOT_ID) != "$(boot_id)" ]] || return 0
        lock_acquire
        st_node_load
        rollback_pending boot || true
        return 0
    fi

    require_managed
    st_node_load
    lock_acquire
    if ((pending)) || { [[ -z $snapshot ]] && pending_exists; }; then
        ((OPT_DRY_RUN)) && { log_info 'dry-run: был бы выполнен откат неподтверждённой конфигурации'; return 0; }
        rollback_pending "$mode" "$txid" || exit "$E_ERROR"
        return 0
    fi

    if [[ -z $snapshot ]]; then
        snapshot="$(snap_list | sed -n 1p)"
        [[ -n $snapshot ]] || die 'снимков нет'
    fi
    local meta
    make_tmp_dir meta
    snap_extract "$snapshot" "$meta"
    [[ $(kv_get "$meta/meta.env" HAD_STATE) == 1 ]] || die "в снимке $snapshot нет состояния (он сделан до init): чтобы убрать интерфейс, используй wg-network destroy"
    log_info "Возврат состояния из снимка $snapshot ($(kv_get "$meta/meta.env" LABEL), $(kv_get "$meta/meta.env" CREATED_AT))"

    tx_begin rollback
    snap_restore_state "$snapshot"
    audit "rollback snapshot=$snapshot"
    apply_changes
    tx_commit
}
