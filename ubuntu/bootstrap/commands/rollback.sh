# shellcheck shell=bash

CMD_SUMMARY='откатить изменения модуля или запуска из бэкапов'
CMD_GROUP=run

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap rollback --pending [--auto|--boot]
               ubuntu-bootstrap rollback RUN_ID [--module NAME]
               ubuntu-bootstrap rollback --last [--module NAME]

  --pending   откатить изменения, ожидающие подтверждения (вызывается и таймером/при загрузке)
  RUN_ID      запуск из `ubuntu-bootstrap history`; восстанавливаются файлы из его бэкапов и
              выполняются зарегистрированные команды отката, в обратном порядке
  --module    только изменения одного модуля этого запуска

Пакеты не удаляются: откат касается конфигурации, сервисов и правил.
EOT
}

cmd_run() {
    local run_id='' module='' pending=0 reason=manual m
    while (($#)); do
        case $1 in
            --pending) pending=1; shift ;;
            --auto) reason='таймер подтверждения истёк'; shift ;;
            --boot) pending=1; reason='перезагрузка до подтверждения'; shift ;;
            --last) run_id="$(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -1)"; shift ;;
            --module) require_arg "$@"; module=$2; shift 2 ;;
            -*) die_usage "неизвестный аргумент: $1" ;;
            *) run_id=$1; shift ;;
        esac
    done
    if ((pending)); then
        pending_exists || { log_info 'нет изменений, ожидающих подтверждения'; return 0; }
        pending_rollback "$reason"
        return
    fi
    [[ -n $run_id ]] || die_usage 'укажи RUN_ID, --last или --pending'
    [[ $run_id =~ ^[0-9-]+$ && -d $RUNS_DIR/$run_id ]] || die "запуск не найден: $run_id (см. ubuntu-bootstrap history)"
    [[ $(kv_get "$RUNS_DIR/$run_id/run.env" DRY_RUN) == 1 ]] && die 'это был dry-run, откатывать нечего'
    log_title "Откат запуска $run_id${module:+, модуль $module}"
    grep "^W$FS\|^D$FS\|^U$FS" "$RUNS_DIR/$run_id/journal" 2>/dev/null | awk -F "$FS" '{ print "  " $1 " " $2 }' | head -40 >&2
    confirm_danger "файлы будут восстановлены из бэкапов запуска $run_id, зарегистрированные команды отката выполнены" || return "$E_REFUSED"
    pending_exists && [[ $(kv_get "$PENDING_FILE" RUN_ID) == "$run_id" ]] && pending_disarm
    LOG_FILE="$LOG_DIR/$run_id.log"
    if tx_rollback_journal "$RUNS_DIR/$run_id/journal" "$module"; then
        log_ok 'откат выполнен'
    else
        log_warn 'откат выполнен с ошибками — проверь вывод выше'
    fi
    while read -r m; do
        [[ -z $module || $m == "$module" ]] || continue
        module_state_set "$m" STATUS rolled_back
        module_state_set "$m" ROLLED_BACK_AT "$(now_iso)"
        module_state_set "$m" CONFIG_HASH ''
    done < <(awk -F "$FS" '$1 == "M" { print $2 }' "$RUNS_DIR/$run_id/journal" | sort -u)
    kv_set "$RUNS_DIR/$run_id/run.env" STATUS rolled_back 600
    audit_log "run=$run_id rolled back${module:+ module=$module} by=manual"
}
