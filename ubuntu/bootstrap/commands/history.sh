# shellcheck shell=bash

CMD_SUMMARY='история запусков, изменённые файлы, бэкапы'
CMD_GROUP=inspect

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap history [RUN_ID]

Без аргумента — таблица запусков. С RUN_ID — журнал изменений запуска (файлы, команды отката).
EOT
}

cmd_run() {
    local d id
    if [[ -n ${1-} ]]; then
        id=$1
        [[ $id =~ ^[0-9-]+$ && -d $RUNS_DIR/$id ]] || die "запуск не найден: $id"
        cat "$RUNS_DIR/$id/run.env"
        printf '\nЖурнал:\n'
        awk -F "$FS" '
            $1 == "M" { printf "  [%s]\n", $2 }
            $1 == "W" { printf "    записан  %s%s\n", $2, ($3 == "-" ? " (новый)" : "") }
            $1 == "D" { printf "    удалён   %s\n", $2 }
            $1 == "U" { $1 = ""; printf "    откат:  %s\n", substr($0, 2) }' OFS=' ' "$RUNS_DIR/$id/journal"
        printf '\nЛог: %s\nБэкапы: %s\n' "$LOG_DIR/$id.log" "$BACKUP_ROOT/$id"
        return 0
    fi
    [[ -d $RUNS_DIR ]] || { log_info 'запусков ещё не было'; return 0; }
    printf '%-22s %-12s %-8s %-7s %s\n' ЗАПУСК СТАТУС КОМАНДА DRY-RUN МОДУЛИ
    for d in "$RUNS_DIR"/*/; do
        [[ -f $d/run.env ]] || continue
        id=${d%/}
        id=${id##*/}
        printf '%-22s %-12s %-8s %-7s %s\n' "$id" "$(kv_get "$d/run.env" STATUS)" "$(kv_get "$d/run.env" COMMAND)" \
            "$(kv_get "$d/run.env" DRY_RUN)" "$(awk -F "$FS" '$1 == "M" { printf "%s ", $2 }' "$d/journal" 2>/dev/null)"
    done
}
