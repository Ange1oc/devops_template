# shellcheck shell=bash
# Transactions: change journal, backups, atomic writes, rollback, deferred rollback (deadman timer).
#
# Journal (RUN_DIR/journal), one record per line, fields separated by FS:
#   M module                 module start
#   W path backup|-          file written (backup = copy of the previous version, "-" = did not exist)
#   D path backup            file removed
#   U argv...                undo command; registered BEFORE the change it reverts, so that the
#                            reverse replay runs it after the files have been restored
# Rolling back a module replays its records (from its M marker to the next one) in reverse.

DRY_RUN=${DRY_RUN:-0}
FILE_CHANGED=0
declare -ga CHANGED_FILES=()

tx_begin() {
    local cmd=$1
    state_dirs_init
    exec {LOCK_FD}> "$LOCK_FILE" || die "не удалось открыть $LOCK_FILE"
    flock -n "$LOCK_FD" || die_code "$E_BUSY" 'ubuntu-bootstrap уже выполняется (другой процесс держит блокировку)'
    RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
    RUN_DIR="$RUNS_DIR/$RUN_ID"
    JOURNAL="$RUN_DIR/journal"
    BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"
    LOG_FILE="$LOG_DIR/$RUN_ID.log"
    install -d -m 700 "$RUN_DIR" "$BACKUP_DIR"
    : > "$JOURNAL"
    (umask 077 && : > "$LOG_FILE")
    printf 'STATUS=running\nCOMMAND=%s\nVERSION=%s\nSTARTED_AT=%s\nDRY_RUN=%s\nUSER=%s\n' \
        "$cmd" "$(ubb_version)" "$(now_iso)" "$DRY_RUN" "${SUDO_USER:-${USER:-root}}" > "$RUN_DIR/run.env"
    audit_log "run=$RUN_ID start cmd=$cmd dry_run=$DRY_RUN"
    EXIT_HOOKS+=(tx_on_exit)
}

tx_on_exit() {
    local rc=$1
    [[ -n ${RUN_DIR-} && -f $RUN_DIR/run.env ]] || return 0
    if [[ $(kv_get "$RUN_DIR/run.env" STATUS) == running ]]; then
        tx_set_status interrupted
        audit_log "run=$RUN_ID interrupted rc=$rc"
    fi
    [[ -d $BACKUP_DIR ]] && rmdir "$BACKUP_DIR" 2>/dev/null
    return 0
}

tx_set_status() {
    kv_set "$RUN_DIR/run.env" STATUS "$1" 600
    kv_set "$RUN_DIR/run.env" FINISHED_AT "$(now_iso)" 600
}

tx_journal() {
    local IFS=$FS
    printf '%s\n' "$*" >> "$JOURNAL"
}

tx_module_begin() {
    CUR_MODULE=$1
    tx_journal M "$1"
}

backup_path() {
    printf '%s%s' "$BACKUP_DIR" "$1"
}

backup_file() {
    local src=$1 dest
    [[ -e $src ]] || return 0
    dest="$(backup_path "$src")"
    install -d -m 700 "$(dirname "$dest")"
    cp -a -- "$src" "$dest"
    printf '%s' "$dest"
}

# file_write PATH [MODE] [OWNER]: stdin -> file. No-op when the content is identical;
# otherwise backs up, journals and replaces atomically. FILE_CHANGED=1 when the content changed.
file_write() {
    local path=$1 mode=${2:-644} owner=${3-} content backup=- diff_out
    content="$(cat; printf x)"
    content=${content%x}
    FILE_CHANGED=0
    if [[ -f $path ]] && [[ $(cat "$path"; printf x) == "${content}x" ]]; then
        file_fix_perms "$path" "$mode" "$owner"
        return 0
    fi
    FILE_CHANGED=1
    CHANGED_FILES+=("$path")
    if ((DRY_RUN)); then
        diff_out="$(diff -u --label "$path" --label "$path (после apply)" "$([[ -f $path ]] && printf '%s' "$path" || printf /dev/null)" - <<< "$content" 2>/dev/null | redact_secrets | head -60)"
        log_plain "${C_YELLOW}[dry-run]${C_RESET} запись $path (mode $mode${owner:+ owner $owner})"
        [[ -n $diff_out ]] && log_plain "$diff_out"
        return 0
    fi
    [[ -e $path ]] && backup="$(backup_file "$path")"
    install -d -m 755 "$(dirname "$path")"
    tx_journal W "$path" "$backup"
    printf '%s' "$content" | write_atomic "$path" "$mode" "$owner"
    log_debug "записан $path"
    _log_file WRITE "$path backup=$backup"
}

# Mode and owner only; not journaled, because restoring the content restores them too.
file_fix_perms() {
    local path=$1 mode=${2:-644} owner=${3-} want_owner
    if [[ $(stat -c %a "$path") != "${mode#0}" ]]; then
        ((DRY_RUN)) || chmod "$mode" "$path"
        log_debug "права $path -> $mode"
    fi
    [[ -n $owner ]] || return 0
    want_owner=$owner
    [[ $owner == *:* ]] || want_owner="$owner:$(id -gn "$owner" 2>/dev/null || printf '%s' "$owner")"
    if [[ $(stat -c '%U:%G' "$path") != "$want_owner" ]]; then
        ((DRY_RUN)) || chown "$want_owner" "$path"
        log_debug "владелец $path -> $want_owner"
    fi
}

file_remove() {
    local path=$1 backup
    [[ -e $path ]] || return 0
    CHANGED_FILES+=("$path (удалён)")
    ((DRY_RUN)) && { log_plain "${C_YELLOW}[dry-run]${C_RESET} удаление $path"; return 0; }
    backup="$(backup_file "$path")"
    tx_journal D "$path" "$backup"
    rm -f -- "$path"
    _log_file REMOVE "$path backup=$backup"
}

# Snapshot of a file an external tool (ufw, certbot) is about to modify, so rollback can restore it.
file_snapshot() {
    local path=$1 backup
    ((DRY_RUN)) && return 0
    if [[ -e $path ]]; then
        backup="$(backup_file "$path")"
        tx_journal W "$path" "$backup"
    else
        tx_journal W "$path" -
    fi
}

# file_set_block PATH MARKER [MODE]: replaces the "# BEGIN MARKER" .. "# END MARKER" block inside a
# foreign file (fstab, after.rules) with stdin; empty stdin removes the block.
file_set_block() {
    local path=$1 marker=$2 mode=${3:-644} body current new
    body="$(cat)"
    current=''
    [[ -f $path ]] && current="$(cat "$path")"
    new="$(awk -v b="# BEGIN $marker" -v e="# END $marker" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }' <<< "$current")"
    if [[ -n $body ]]; then
        [[ -n $new ]] && new+=$'\n'
        new+="# BEGIN $marker"$'\n'"$body"$'\n'"# END $marker"
    fi
    [[ -n $new ]] && new+=$'\n'
    printf '%s' "$new" | file_write "$path" "$mode"
}

# Register an undo command (before the change it reverts).
undo() {
    ((DRY_RUN)) && return 0
    tx_journal U "$@"
}

redact_secrets() {
    sed -E 's/^((PrivateKey|PresharedKey|PASSWORD|.*SECRET.*|.*TOKEN.*|.*password.*)[[:space:]]*[=:][[:space:]]*).*/\1(скрыто)/'
}

# Run a command: output goes to the log, the last lines are shown on failure; dry-run only prints it.
run() {
    local rc out
    _log_file CMD "$*"
    if ((DRY_RUN)); then
        log_plain "${C_YELLOW}[dry-run]${C_RESET} $*"
        return 0
    fi
    # The child ignores SIGHUP so a dropped SSH session cannot interrupt apt/dpkg half-way;
    # bash handles the signal after the command returns (ui_on_hangup).
    out="$(trap '' HUP; "$@" 2>&1)"
    rc=$?
    [[ -n $out ]] && printf '%s\n' "$out" >> "${LOG_FILE:-/dev/null}"
    if ((rc)); then
        log_error "команда завершилась с кодом $rc: $*"
        [[ -n $out ]] && printf '%s\n' "$out" | tail -n 8 | sed 's/^/    /' >&2
    fi
    return "$rc"
}

# tx_rollback_journal JOURNAL [MODULE]: replay the records of MODULE (or the whole run) in reverse.
tx_rollback_journal() {
    local journal=$1 module=${2-} line t a b cur='' rc=0
    local -a entries=() argv
    [[ -s $journal ]] || return 0
    while IFS= read -r line; do
        IFS=$FS read -r t a _ <<< "$line"
        [[ $t == M ]] && { cur=$a; continue; }
        [[ -z $module || $cur == "$module" ]] && entries+=("$cur$FS$line")
    done < "$journal"
    # Undo commands may be module functions, so the module is loaded before they run.
    local i loaded=''
    for ((i = ${#entries[@]} - 1; i >= 0; i--)); do
        IFS=$FS read -r cur t a b <<< "${entries[i]}"
        if [[ $cur != "$loaded" && -n ${MOD_FILE_OF[$cur]-} ]]; then
            module_load "$cur"
            loaded=$cur
        fi
        case $t in
            W | D)
                if [[ $b != - && -e $b ]]; then
                    install -d -m 755 "$(dirname "$a")"
                    cp -a -- "$b" "$a" && log_info "восстановлен $a" || { log_error "не удалось восстановить $a"; rc=1; }
                elif [[ $b == - ]]; then
                    rm -f -- "$a" && log_info "удалён созданный $a"
                fi
                ;;
            U)
                IFS=$FS read -r -a argv <<< "${entries[i]#"$cur$FS"U$FS}"
                _log_file UNDO "${argv[*]}"
                "${argv[@]}" >> "${LOG_FILE:-/dev/null}" 2>&1 || { log_warn "команда отката завершилась с ошибкой: ${argv[*]}"; rc=1; }
                ;;
        esac
    done
    return "$rc"
}

# ---- deferred rollback: a timer outside the SSH session, cancelled by `confirm` ----

pending_exists() { [[ -f $PENDING_FILE ]]; }

# pending_arm MODULE SECONDS DESCRIPTION: the module rolls itself back when the deadline passes.
pending_arm() {
    local module=$1 seconds=$2 desc=$3 unit mech timer
    local -a cmd=("$UBB_HOME/ubuntu-bootstrap" --quiet rollback --pending --auto)
    ((DRY_RUN)) && { log_info "[dry-run] таймер отката ${seconds}s для $module"; return 0; }
    pending_disarm
    if ((F_HAS_SYSTEMD)) && has_cmd systemd-run; then
        unit="ubuntu-bootstrap-rollback-$module"
        systemctl stop "$unit.timer" 2>/dev/null || true
        systemd-run --quiet --unit "$unit" --description "ubuntu-bootstrap: откат $module без подтверждения" \
            --on-active="${seconds}s" --timer-property=AccuracySec=1s "${cmd[@]}" >/dev/null {LOCK_FD}>&- || die 'не удалось запустить таймер отката'
        mech=systemd timer="$unit.timer"
    else
        # shellcheck disable=SC2016
        setsid bash -c 'sleep "$1"; shift; exec "$@"' _ "$seconds" "${cmd[@]}" </dev/null >/dev/null 2>&1 {LOCK_FD}>&- &
        mech=setsid timer=$!
    fi
    printf 'RUN_ID=%s\nMODULE=%s\nDEADLINE=%s\nMECH=%s\nTIMER=%s\nDESC=%s\n' \
        "$RUN_ID" "$module" "$(($(now_epoch) + seconds))" "$mech" "$timer" "$desc" | write_atomic "$PENDING_FILE" 600
    audit_log "run=$RUN_ID module=$module pending armed ${seconds}s"
}

pending_disarm() {
    pending_exists || return 0
    local mech timer
    mech="$(kv_get "$PENDING_FILE" MECH)"
    timer="$(kv_get "$PENDING_FILE" TIMER)"
    case $mech in
        systemd) systemctl stop "$timer" 2>/dev/null || true ;;
        setsid)
            [[ $timer =~ ^[0-9]+$ ]] && tr '\0' ' ' < "/proc/$timer/cmdline" 2>/dev/null | grep -q 'rollback --pending' && kill "$timer" 2>/dev/null
            ;;
    esac
    rm -f -- "$PENDING_FILE"
}

pending_confirm() {
    pending_exists || return 1
    local module run_id
    module="$(kv_get "$PENDING_FILE" MODULE)"
    run_id="$(kv_get "$PENDING_FILE" RUN_ID)"
    pending_disarm
    module_state_set "$module" CONFIRMED_AT "$(now_iso)"
    audit_log "run=$run_id module=$module confirmed"
    log_ok "изменения модуля $module подтверждены"
    if [[ -n ${MOD_FILE_OF[$module]-} ]]; then
        module_load "$module"
        CUR_MODULE_LOAD=$module
        mod_confirmed
        unset CUR_MODULE_LOAD
    fi
}

# pending_rollback REASON: roll back the module waiting for confirmation.
pending_rollback() {
    local reason=$1 module run_id rc=0
    pending_exists || return 0
    module="$(kv_get "$PENDING_FILE" MODULE)"
    run_id="$(kv_get "$PENDING_FILE" RUN_ID)"
    LOG_FILE="$LOG_DIR/$run_id.log"
    log_warn "откат модуля $module (запуск $run_id): $reason"
    pending_disarm
    tx_rollback_journal "$RUNS_DIR/$run_id/journal" "$module" || rc=1
    module_state_set "$module" ROLLED_BACK_AT "$(now_iso)"
    module_state_set "$module" STATUS rolled_back
    module_state_set "$module" CONFIG_HASH ''
    audit_log "run=$run_id module=$module rolled back reason=$reason"
    return "$rc"
}

# ---- module state ----

module_state_file() { printf '%s/%s.env' "$MOD_STATE_DIR" "$1"; }

module_state_set() {
    local f
    f="$(module_state_file "$1")"
    [[ -d $MOD_STATE_DIR ]] || install -d -m 700 "$MOD_STATE_DIR"
    [[ -f $f ]] || : > "$f"
    kv_set "$f" "$2" "$3" 600
}

module_state_get() {
    kv_get "$(module_state_file "$1")" "$2"
}

# Hash of the module's effective options; a different hash means the module must be re-applied.
module_config_hash() {
    local m=$1 name out=''
    for name in "${OPT_ORDER[@]}"; do
        [[ ${OPT_MODULE[$name]} == "$m" ]] && out+="$name=$(cfg "$name")"$'\n'
    done
    sha256_str "$out"
}
