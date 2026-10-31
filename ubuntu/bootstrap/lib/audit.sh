# shellcheck shell=bash
# Check accumulator for mod_audit, audit and doctor: rows are collected, then printed as a table or JSON.

declare -ga AUDIT_ROWS=()
AUDIT_OK=0 AUDIT_WARN=0 AUDIT_FAIL=0

# check_ok|warn|fail|info DESCRIPTION [HINT]
check_ok()   { AUDIT_OK=$((AUDIT_OK + 1));     AUDIT_ROWS+=("ok${FS}${CUR_MODULE_LOAD:-system}${FS}$1${FS}${2-}"); }
check_warn() { AUDIT_WARN=$((AUDIT_WARN + 1)); AUDIT_ROWS+=("warn${FS}${CUR_MODULE_LOAD:-system}${FS}$1${FS}${2-}"); }
check_fail() { AUDIT_FAIL=$((AUDIT_FAIL + 1)); AUDIT_ROWS+=("fail${FS}${CUR_MODULE_LOAD:-system}${FS}$1${FS}${2-}"); }
check_info() { AUDIT_ROWS+=("info${FS}${CUR_MODULE_LOAD:-system}${FS}$1${FS}${2-}"); }

audit_print() {
    local row status mod desc hint mark color
    for row in "${AUDIT_ROWS[@]}"; do
        IFS=$FS read -r status mod desc hint <<< "$row"
        case $status in
            ok) mark='✓' color=$C_GREEN ;;
            warn) mark='!' color=$C_YELLOW ;;
            fail) mark='✗' color=$C_RED ;;
            *) mark='·' color=$C_DIM ;;
        esac
        printf '  %s%s%s %-10s %s%s\n' "$color" "$mark" "$C_RESET" "$mod" "$desc" "${hint:+ ${C_DIM}— $hint$C_RESET}"
    done
    printf '\n%sИтог:%s %d ok, %d предупреждений, %d проблем\n' "$C_BOLD" "$C_RESET" "$AUDIT_OK" "$AUDIT_WARN" "$AUDIT_FAIL"
}

audit_json() {
    local row status mod desc hint first=1
    printf '{"ok":%d,"warn":%d,"fail":%d,"checks":[' "$AUDIT_OK" "$AUDIT_WARN" "$AUDIT_FAIL"
    for row in "${AUDIT_ROWS[@]}"; do
        IFS=$FS read -r status mod desc hint <<< "$row"
        ((first)) || printf ','
        first=0
        printf '{"status":%s,"module":%s,"check":%s,"hint":%s}' "$(json_str "$status")" "$(json_str "$mod")" "$(json_str "$desc")" "$(json_str "$hint")"
    done
    printf ']}\n'
}

audit_exit_code() {
    ((AUDIT_FAIL)) && return 2
    ((AUDIT_WARN)) && return 1
    return 0
}
