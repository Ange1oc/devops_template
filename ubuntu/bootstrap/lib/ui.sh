# shellcheck shell=bash
# Dialogue with the administrator.
#
# Interactive when stdin is a terminal or /dev/tty is usable (curl | bash). --yes answers every
# question with its default. Without a TTY and without --yes a dangerous action (confirm_danger)
# is refused; guards (guard_refuse) are independent of this and yield only to --force.

UI_TTY=''

ui_init() {
    UI_TTY=''
    ((OPT_YES)) && return 0
    if [[ -t 0 ]]; then
        UI_TTY=/dev/stdin
    elif [[ -r /dev/tty && -w /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then
        UI_TTY=/dev/tty
    fi
}

interactive() { [[ -n $UI_TTY ]]; }

# SIGHUP (dropped SSH session): continue without a terminal, output goes to the run log.
ui_on_hangup() {
    UI_TTY=''
    [[ -n ${LOG_FILE-} ]] && exec >> "$LOG_FILE" 2>&1
    log_warn 'терминал потерян (SIGHUP) — продолжаю в фоне, вывод в логе'
}

# shellcheck disable=SC2094  # /dev/tty is read and written on purpose
_ui_read() {
    local -n _r_out=$1
    local prompt=$2
    read -r -p "$prompt" _r_out < "$UI_TTY" 2> "$UI_TTY" || { _r_out=''; return 1; }
}

# ask_yn QUESTION [y|n] -> 0 yes / 1 no.
ask_yn() {
    local q=$1 def=${2:-y} hint ans
    if ! interactive; then
        _log_file ASK "$q -> auto:$def"
        [[ $def == y ]]
        return
    fi
    [[ $def == y ]] && hint='Y/n' || hint='y/N'
    while true; do
        _ui_read ans "${C_BOLD}${q}${C_RESET} [$hint]: " || { [[ $def == y ]]; return; }
        ans=${ans:-$def}
        case ${ans,,} in
            y | yes | д | да) _log_file ASK "$q -> yes"; return 0 ;;
            n | no | н | нет) _log_file ASK "$q -> no"; return 1 ;;
        esac
    done
}

# ask_input VAR PROMPT DEFAULT [VALIDATOR]: the validator makes the question repeat on bad input.
ask_input() {
    local -n _ai_out=$1
    local prompt=$2 def=$3 validator=${4-} _ai_ans
    if ! interactive; then
        _ai_out=$def
        return 0
    fi
    while true; do
        _ui_read _ai_ans "${prompt}${def:+ [$def]}: " || { _ai_out=$def; return 0; }
        _ai_ans=${_ai_ans:-$def}
        if [[ -z $validator ]] || "$validator" "$_ai_ans"; then
            _ai_out=$_ai_ans
            _log_file ASK "$prompt -> $_ai_ans"
            return 0
        fi
        printf '%s  некорректное значение%s\n' "$C_RED" "$C_RESET" > "$UI_TTY"
    done
}

# ask_secret VAR PROMPT: no echo, not logged.
# shellcheck disable=SC2094
ask_secret() {
    local -n _as_out=$1
    interactive || { _as_out=''; return 1; }
    read -r -s -p "$2: " _as_out < "$UI_TTY" 2> "$UI_TTY"
    printf '\n' > "$UI_TTY"
}

# ask_choice VAR TITLE DEFAULT_INDEX ITEM... -> 1-based index.
ask_choice() {
    local -n _ac_out=$1
    local title=$2 def=$3 _ac_ans i
    shift 3
    local -a _ac_items=("$@")
    if ! interactive; then
        _ac_out=$def
        return 0
    fi
    printf '%s%s%s\n' "$C_BOLD" "$title" "$C_RESET" > "$UI_TTY"
    for i in "${!_ac_items[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${_ac_items[i]}" > "$UI_TTY"; done
    while true; do
        _ui_read _ac_ans "Выбор [$def]: " || { _ac_out=$def; return 0; }
        _ac_ans=${_ac_ans:-$def}
        if is_uint "$_ac_ans" && ((_ac_ans >= 1 && _ac_ans <= ${#_ac_items[@]})); then
            _ac_out=$_ac_ans
            _log_file ASK "$title -> $_ac_ans"
            return 0
        fi
    done
}

# Dangerous action: the word "yes" must be typed. --yes accepts; no TTY and no --yes refuses.
# Dry-run only reports that a confirmation would be required.
confirm_danger() {
    local msg=$1 ans
    if ((DRY_RUN)); then
        log_plain "${C_YELLOW}[dry-run]${C_RESET} потребуется подтверждение: $msg"
        return 0
    fi
    if ((OPT_YES)); then
        _log_file ASK "DANGER '$msg' -> --yes"
        return 0
    fi
    if ! interactive; then
        log_error "требуется подтверждение: $msg"
        log_error 'неинтерактивный режим: добавь --yes, чтобы принять, или исключи модуль (--skip)'
        return 1
    fi
    printf '%s%sВНИМАНИЕ:%s %s\n' "$C_RED" "$C_BOLD" "$C_RESET" "$msg" > "$UI_TTY"
    _ui_read ans "Введи 'yes' для подтверждения (иначе отмена): " || return 1
    [[ $ans == yes ]]
}

# Countdown prompt: 0 = yes, 1 = no or timeout, 2 = the pending state was removed by another
# process (`confirm` from a second session, or the rollback timer fired).
wait_confirmation() {
    local seconds=$1 question=$2 ans='' deadline
    deadline=$(($(now_epoch) + seconds))
    while (($(now_epoch) < deadline)); do
        pending_exists || return 2
        if interactive; then
            printf '\r%s%s%s [y/N] (откат через %3d с): ' "$C_BOLD" "$question" "$C_RESET" $((deadline - $(now_epoch))) > "$UI_TTY"
            if read -r -t 5 ans < "$UI_TTY" 2>/dev/null; then
                printf '\n' > "$UI_TTY"
                case ${ans,,} in
                    y | yes | д | да) return 0 ;;
                    n | no | н | нет) return 1 ;;
                esac
            fi
        else
            sleep 5
        fi
    done
    return 1
}

hr() { log_plain '------------------------------------------------------------'; }
